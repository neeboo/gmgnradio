//! Public reference discovery and durable per-claimed-turn registration decisions.
use crate::{model::Result, store::Database};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
const MAX_JSON: usize = 2 * 1024 * 1024;
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS wish_reference_urls(turn TEXT,url TEXT,state TEXT,token TEXT,payload TEXT,PRIMARY KEY(turn,url)); CREATE TABLE IF NOT EXISTS wish_reference_calls(turn TEXT,call TEXT,input TEXT,url TEXT,PRIMARY KEY(turn,call)); CREATE TABLE IF NOT EXISTS wish_reference_cooldown(turn TEXT PRIMARY KEY,until_ms INTEGER,failure TEXT);").map_err(|_| "storage_unavailable")
}
fn text<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 4096)
        .ok_or("reference_invalid_arguments")
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}
fn turn(p: &Value) -> Result<String> {
    Ok(serde_json::to_string(&[
        text(p, "worldID")?,
        text(p, "residentScope")?,
        text(p, "hostSessionID")?,
        text(p, "runID")?,
    ])
    .unwrap())
}
fn authorized(c: &Connection, p: &Value, tool: &str) -> Result<String> {
    if text(p, "toolName")? != tool {
        return Err("reference_registration_unauthorized");
    }
    let active:bool=c.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_events WHERE world=?1 AND scope=?2 AND session=?3 AND run=?4 AND state='claimed')",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"hostSessionID")?,text(p,"runID")?],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
    let actual:bool=c.query_row("SELECT EXISTS(SELECT 1 FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND session=?3 AND run=?4 AND call=?5 AND operation=?6 AND tool=?7 AND state='inflight')",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"hostSessionID")?,text(p,"runID")?,text(p,"callID")?,text(p,"operationID")?,tool],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
    if !active || !actual {
        return Err("stale_wish_reference_session");
    }
    let raw:String=c.query_row("SELECT input FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND session=?3 AND run=?4 AND call=?5",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"hostSessionID")?,text(p,"runID")?,text(p,"callID")?],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
    let actual_input: Value = serde_json::from_str(&raw).map_err(|_| "reference_call_conflict")?;
    let supplied = if tool == "search_wish_reference_images" {
        json!({"query":p["query"]})
    } else {
        json!({"image_url":p["image_url"],"display_name":p["display_name"]})
    };
    if actual_input != supplied {
        return Err("reference_call_conflict");
    }
    turn(p)
}
fn public_url(raw: &str, image: bool) -> Option<reqwest::Url> {
    if raw.chars().count() > 2048 {
        return None;
    }
    let u = reqwest::Url::parse(raw).ok()?;
    (u.scheme() == "https"
        && u.host_str().is_some()
        && u.username().is_empty()
        && u.password().is_none()
        && (!image || u.fragment().is_none())
        && (!image || u.port().is_none_or(|p| p == 443)))
    .then_some(u)
}
fn failure(code: &str, reason: &str, connectivity: bool) -> Value {
    json!({"ok":false,"code":code,"reason":reason,"isConnectivity":connectivity,"message":format!("公开参考图服务失败：{reason}。请检查网络或代理配置后重试。"),"screen":format!("参考图服务失败：{reason}")})
}
fn store_failure(c: &Connection, key: &str, v: &Value) -> Result<()> {
    if v["isConnectivity"] == true {
        c.execute(
            "INSERT OR REPLACE INTO wish_reference_cooldown VALUES(?1,?2,?3)",
            params![key, now() + 30000, v.to_string()],
        )
        .map_err(|_| "storage_unavailable")?;
    }
    Ok(())
}
fn search_prepare(c: &Connection, p: &Value) -> Result<Value> {
    let key = authorized(c, p, "search_wish_reference_images")?;
    let query = text(p, "query")?.trim();
    if query.is_empty() || query.chars().count() > 200 {
        return Err("reference_invalid_arguments");
    }
    let cool: Option<(i64, String)> = c
        .query_row(
            "SELECT until_ms,failure FROM wish_reference_cooldown WHERE turn=?1",
            [&key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((until, raw)) = cool.filter(|(until, _)| *until > now()) {
        let mut v: Value = serde_json::from_str(&raw).map_err(|_| "storage_unavailable")?;
        v["code"] = json!("reference_search_cooling_down");
        v["message"] = json!(format!(
            "本次没有发起搜索，连接失败冷却剩余 {} 秒。{}",
            (until - now() + 999) / 1000,
            v["message"].as_str().unwrap_or("")
        ));
        return Ok(v);
    }
    let mut url = reqwest::Url::parse("https://commons.wikimedia.org/w/api.php").unwrap();
    url.query_pairs_mut().extend_pairs([
        ("action", "query"),
        ("generator", "search"),
        ("gsrnamespace", "6"),
        ("gsrlimit", "5"),
        ("prop", "imageinfo"),
        ("iiprop", "url|extmetadata"),
        ("iiurlwidth", "1024"),
        ("format", "json"),
        ("gsrsearch", query),
    ]);
    Ok(json!({"ok":true,"url":url.as_str(),"query":query}))
}
fn parse_search(data: &[u8]) -> Result<Value> {
    let root: Value = serde_json::from_slice(data).map_err(|_| "reference_search_unparseable")?;
    if let Some(error) = root.get("error") {
        return Ok(failure(
            "reference_search_api_error",
            &error.to_string(),
            false,
        ));
    }
    let pages = &root["query"]["pages"];
    let list: Vec<&Value> = if let Some(o) = pages.as_object() {
        o.values().collect()
    } else {
        pages
            .as_array()
            .map(|v| v.iter().collect())
            .unwrap_or_default()
    };
    let mut results = vec![];
    for page in list {
        let Some(title) = page["title"]
            .as_str()
            .filter(|s| !s.is_empty() && s.chars().count() <= 300)
        else {
            continue;
        };
        let info = &page["imageinfo"][0];
        let Some(image) = info["thumburl"]
            .as_str()
            .or_else(|| info["url"].as_str())
            .and_then(|s| public_url(s, true))
        else {
            continue;
        };
        let source = info["descriptionurl"]
            .as_str()
            .and_then(|s| public_url(s, false))
            .unwrap_or_else(|| {
                let mut u = reqwest::Url::parse("https://commons.wikimedia.org/wiki/").unwrap();
                u.path_segments_mut()
                    .unwrap()
                    .push(&title.replace(' ', "_"));
                u
            });
        results.push(json!({"title":title,"image_url":image.as_str(),"source_page_url":source.as_str(),"source":"wikimedia_commons","license_verified":false}));
        if results.len() == 5 {
            break;
        }
    }
    Ok(
        json!({"ok":true,"total":results.len(),"results":results,"license_notice":"图片来自公开网页，版权与许可未核验；仅供本机个人测试，不得声称已核验授权。","message":"请选择真实直链，用 register_wish_reference_image 登记；没有结果时不得编造链接。"}),
    )
}
pub async fn search(db: Database, p: Value) -> Result<Value> {
    let input = p.clone();
    let prepared = db
        .call(move |s| search_prepare(&s.connection, &input))
        .await?;
    if prepared["ok"] != true {
        return Ok(prepared);
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| "reference_search_unavailable")?;
    let fetched = async {
        let mut response = client
            .get(prepared["url"].as_str().unwrap())
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    failure("reference_search_timeout", "request-timeout", true)
                } else {
                    failure(
                        "reference_search_connection_failed",
                        "request-connect-failed",
                        true,
                    )
                }
            })?;
        if !response.status().is_success() {
            return Err(failure(
                "reference_search_http_error",
                &format!("http-status-{}", response.status().as_u16()),
                false,
            ));
        }
        let mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .trim()
            .to_ascii_lowercase();
        if mime != "application/json" && mime != "text/json" && !mime.ends_with("+json") {
            return Err(failure(
                "reference_search_not_json",
                &format!("mime:{mime}"),
                false,
            ));
        }
        let mut bytes = vec![];
        while let Some(chunk) = response.chunk().await.map_err(|_| {
            failure(
                "reference_search_connection_failed",
                "response-read-failed",
                true,
            )
        })? {
            if bytes.len() + chunk.len() > MAX_JSON {
                return Err(failure(
                    "reference_search_response_too_large",
                    "response-over-2MiB",
                    false,
                ));
            }
            bytes.extend_from_slice(&chunk);
        }
        parse_search(&bytes).map_err(|code| failure(code, "json-unparseable", false))
    }
    .await;
    let mut result = fetched.unwrap_or_else(|v| v);
    result["query"] = prepared["query"].clone();
    db.call(move |s| {
        let key = authorized(&s.connection, &p, "search_wish_reference_images")?;
        if result["ok"] == true {
            s.connection
                .execute("DELETE FROM wish_reference_cooldown WHERE turn=?1", [key])
                .map_err(|_| "storage_unavailable")?;
        } else {
            store_failure(&s.connection, &key, &result)?;
        }
        Ok(result)
    })
    .await
}
fn actual_registration(c: &Connection, p: &Value, url: &str, prepared: &Value) -> Result<Value> {
    let grant = text(p, "authorizationID")?;
    let id = prepared["attachment_id"].as_str().unwrap();
    let mut stmt = c
        .prepare("SELECT payload FROM wish_control_documents")
        .map_err(|_| "storage_unavailable")?;
    let archives = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|_| "storage_unavailable")?;
    let mut verified = false;
    for raw in archives {
        let a: Value = serde_json::from_str(&raw.map_err(|_| "storage_unavailable")?)
            .map_err(|_| "storage_unavailable")?;
        let auth = a["authorizations"].as_array().and_then(|rows| {
            rows.iter().find(|v| {
                v["id"]
                    .as_str()
                    .is_some_and(|s| s.eq_ignore_ascii_case(grant))
                    && v["worldID"] == p["worldID"]
                    && v["residentScope"] == p["residentScope"]
            })
        });
        verified |= auth.is_some_and(|a| {
            a["attachments"].as_array().is_some_and(|rows| {
                rows.iter()
                    .any(|v| v["id"].as_str().is_some_and(|s| s.eq_ignore_ascii_case(id)))
            })
        }) && a["webReferences"].as_array().is_some_and(|rows| {
            rows.iter().any(|v| {
                v["attachmentID"]
                    .as_str()
                    .is_some_and(|s| s.eq_ignore_ascii_case(id))
                    && v["imageURL"] == url
            })
        });
    }
    if !verified {
        return Err("reference_registration_unverified");
    }

    Ok(
        json!({"ok":true,"attachment_id":id,"display_name":prepared["display_name"],"source_image_url":url,"source_kind":"public_web_reference","license_verified":false,"message":"已登记为本轮参考图，来源和许可没有核实。用户明确要做的时候，再提交生成。"}),
    )
}
pub fn request(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let key = authorized(c, p, "register_wish_reference_image")?;
    let raw = text(p, "image_url")?;
    let url = public_url(raw, true)
        .ok_or("reference_invalid_arguments")?
        .to_string();
    let name = text(p, "display_name")?;
    if name.trim().is_empty() || name.chars().count() > 100 {
        return Err("reference_invalid_arguments");
    }
    let grant = text(p, "authorizationID")?;
    let human:bool=c.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_events WHERE world=?1 AND scope=?2 AND session=?3 AND run=?4 AND state='claimed' AND json_extract(payload,'$.kind')='human') OR EXISTS(SELECT 1 FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 AND session=?3 AND run=?4 AND ((state='claimed' AND mode='human') OR (state='delivered' AND mode='steering')))",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"hostSessionID")?,text(p,"runID")?],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
    if !human || !grant.eq_ignore_ascii_case(text(p, "runID")?) {
        return Err("reference_registration_unauthorized");
    }
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let call = text(p, "callID")?;
    let input = json!({"image_url":raw,"display_name":name}).to_string();
    let old: Option<String> = tx
        .query_row(
            "SELECT input FROM wish_reference_calls WHERE turn=?1 AND call=?2",
            params![key, call],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if old.as_ref().is_some_and(|s| s != &input) {
        return Err("reference_call_conflict");
    }
    let mut prior: Option<(String, String, String)> = tx
        .query_row(
            "SELECT state,token,payload FROM wish_reference_urls WHERE turn=?1 AND url=?2",
            params![key, url],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if method == "wish_reference_prepare"
        && old.is_none()
        && prior.as_ref().is_some_and(|v| v.0 == "failed")
    {
        tx.execute(
            "DELETE FROM wish_reference_urls WHERE turn=?1 AND url=?2",
            params![key, url],
        )
        .map_err(|_| "storage_unavailable")?;
        prior = None;
    }
    let output = match method {
        "wish_reference_prepare" => {
            tx.execute(
                "INSERT OR IGNORE INTO wish_reference_calls VALUES(?1,?2,?3,?4)",
                params![key, call, input, url],
            )
            .map_err(|_| "storage_unavailable")?;
            if let Some((state, token, raw)) = prior {
                let v: Value = serde_json::from_str(&raw).map_err(|_| "storage_unavailable")?;
                if state == "registered" || state == "failed" {
                    v
                } else if let Ok(receipt) = actual_registration(&tx, p, &url, &v) {
                    tx.execute("UPDATE wish_reference_urls SET state='registered',payload=?3 WHERE turn=?1 AND url=?2",params![key,url,receipt.to_string()]).map_err(|_|"storage_unavailable")?;
                    receipt
                } else if v["startedAtMillis"]
                    .as_i64()
                    .is_some_and(|started| now() - started > 30000)
                {
                    let expired = failure(
                        "reference_registration_incomplete",
                        "download-receipt-missing",
                        false,
                    );
                    tx.execute("UPDATE wish_reference_urls SET state='failed',payload=?3 WHERE turn=?1 AND url=?2",params![key,url,expired.to_string()]).map_err(|_|"storage_unavailable")?;
                    expired
                } else {
                    json!({"ok":true,"action":"wait","token":token})
                }
            } else {
                let token = uuid::Uuid::new_v4().to_string();
                let v = json!({"ok":true,"action":"download","token":token,"image_url":url,"display_name":name,"attachment_id":uuid::Uuid::new_v4().to_string(),"startedAtMillis":now()});
                tx.execute(
                    "INSERT INTO wish_reference_urls VALUES(?1,?2,'downloading',?3,?4)",
                    params![key, url, token, v.to_string()],
                )
                .map_err(|_| "storage_unavailable")?;
                v
            }
        }
        "wish_reference_complete" => {
            let (state, token, raw) = prior.ok_or("reference_call_conflict")?;
            if token != text(p, "token")? {
                return Err("reference_call_conflict");
            }
            if state != "downloading" {
                serde_json::from_str(&raw).map_err(|_| "storage_unavailable")?
            } else {
                let prepared: Value =
                    serde_json::from_str(&raw).map_err(|_| "storage_unavailable")?;
                let v = if p["success"] == true {
                    actual_registration(&tx, p, &url, &prepared)?
                } else {
                    failure(
                        p["code"]
                            .as_str()
                            .unwrap_or("reference_registration_failed"),
                        p["reason"].as_str().unwrap_or("native-download-failed"),
                        p["isConnectivity"] == true,
                    )
                };
                store_failure(&tx, &key, &v)?;
                if v["ok"] == true {
                    tx.execute("DELETE FROM wish_reference_cooldown WHERE turn=?1", [&key])
                        .map_err(|_| "storage_unavailable")?;
                }
                tx.execute(
                    "UPDATE wish_reference_urls SET state=?3,payload=?4 WHERE turn=?1 AND url=?2",
                    params![
                        key,
                        url,
                        if v["ok"] == true {
                            "registered"
                        } else {
                            "failed"
                        },
                        v.to_string()
                    ],
                )
                .map_err(|_| "storage_unavailable")?;
                v
            }
        }
        _ => return Err("unknown_method"),
    };
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(tool: &str, input: Value) -> (Connection, Value) {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        c.execute_batch("CREATE TABLE agent_loop_events(world TEXT,scope TEXT,session TEXT,run TEXT,state TEXT,payload TEXT);CREATE TABLE agent_loop_human_messages(world TEXT,scope TEXT,session TEXT,run TEXT,state TEXT,mode TEXT);CREATE TABLE agent_tool_calls(world TEXT,scope TEXT,session TEXT,run TEXT,call TEXT,operation TEXT,tool TEXT,state TEXT,input TEXT);CREATE TABLE wish_control_documents(payload TEXT);").unwrap();
        c.execute("INSERT INTO agent_loop_events VALUES('w','s','h','r','claimed','{\"kind\":\"human\"}')",[]).unwrap();
        c.execute(
            "INSERT INTO agent_tool_calls VALUES('w','s','h','r','c','o',?1,'inflight',?2)",
            params![tool, input.to_string()],
        )
        .unwrap();
        let mut p = input;
        p["worldID"] = json!("w");
        p["residentScope"] = json!("s");
        p["hostSessionID"] = json!("h");
        p["runID"] = json!("r");
        p["callID"] = json!("c");
        p["operationID"] = json!("o");
        p["toolName"] = json!(tool);
        p["authorizationID"] = json!("r");
        (c, p)
    }
    #[test]
    fn real_claim_and_exact_ledger_input_required() {
        let (mut c, mut p) = fixture(
            "register_wish_reference_image",
            json!({"image_url":"https://example.org/a.png","display_name":"chair"}),
        );
        let first = request(&mut c, "wish_reference_prepare", &p).unwrap();
        assert_eq!(first["action"], "download");
        assert_eq!(
            request(&mut c, "wish_reference_prepare", &p).unwrap()["action"],
            "wait"
        );
        p["image_url"] = json!("https://example.org/other.png");
        assert_eq!(
            request(&mut c, "wish_reference_prepare", &p),
            Err("reference_call_conflict")
        );
        p["image_url"] = json!("https://example.org/a.png");
        c.execute("UPDATE agent_loop_events SET state='cancelled'", [])
            .unwrap();
        assert_eq!(
            request(&mut c, "wish_reference_prepare", &p),
            Err("stale_wish_reference_session")
        );
    }
    #[test]
    fn download_claim_is_not_registration_receipt() {
        let (mut c, mut p) = fixture(
            "register_wish_reference_image",
            json!({"image_url":"https://example.org/a.png","display_name":"chair"}),
        );
        let prepared = request(&mut c, "wish_reference_prepare", &p).unwrap();
        p["token"] = prepared["token"].clone();
        p["success"] = json!(true);
        assert_eq!(
            request(&mut c, "wish_reference_complete", &p),
            Err("reference_registration_unverified")
        );
        let id = prepared["attachment_id"].as_str().unwrap();
        let archive = json!({"authorizations":[{"id":"r","worldID":"w","residentScope":"s","attachments":[{"id":id}]}],"webReferences":[{"attachmentID":id,"imageURL":"https://example.org/a.png"}]});
        c.execute(
            "INSERT INTO wish_control_documents VALUES(?1)",
            [archive.to_string()],
        )
        .unwrap();
        let receipt = request(&mut c, "wish_reference_complete", &p).unwrap();
        assert_eq!(receipt["ok"], true);
        assert_eq!(receipt["attachment_id"], id);
        assert_eq!(
            request(&mut c, "wish_reference_complete", &p).unwrap(),
            receipt
        );
    }
    #[test]
    fn search_cooldown_expires_and_real_empty_response_is_success() {
        let (c, p) = fixture("search_wish_reference_images", json!({"query":"red chair"}));
        let key = turn(&p).unwrap();
        let fact = failure("reference_search_timeout", "request-timeout", true);
        store_failure(&c, &key, &fact).unwrap();
        assert_eq!(
            search_prepare(&c, &p).unwrap()["code"],
            "reference_search_cooling_down"
        );
        c.execute("UPDATE wish_reference_cooldown SET until_ms=0", [])
            .unwrap();
        let ready = search_prepare(&c, &p).unwrap();
        assert_eq!(ready["ok"], true);
        assert!(ready["url"]
            .as_str()
            .unwrap()
            .starts_with("https://commons.wikimedia.org/w/api.php?"));
        assert_eq!(
            parse_search(br#"{\"query\":{\"pages\":[]}}"#).is_err(),
            true
        );
        assert_eq!(
            parse_search(b"{\"query\":{\"pages\":[]}}").unwrap()["total"],
            0
        );
        assert_eq!(
            parse_search(b"{\"error\":{\"code\":\"badvalue\"}}").unwrap()["ok"],
            false
        );
    }
    #[test]
    fn public_links_reject_credentials_fragments_and_nonstandard_ports() {
        for url in [
            "http://example.org/a",
            "https://user:pass@example.org/a",
            "https://example.org/a#x",
            "https://example.org:444/a",
        ] {
            assert!(public_url(url, true).is_none());
        }
        assert!(public_url("https://example.org/a.png", true).is_some());
    }
}
