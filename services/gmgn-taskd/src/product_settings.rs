//! Private host product preferences. Never registered as a model capability.
//! Credentials are intentionally absent from this authority and its snapshots.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub const DEFAULT_PERSONA: &str = "你是一位有自己生活节奏的居民：说话自然、简短，先观察再行动。\n你可以按自己的偏好安排生活，也可以直接表达自己的判断和感受，不必每句话都请示。";
pub const DEFAULT_MOTION_CATALOG: &str = "https://192.168.1.85:8765/catalog.json";
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS product_settings(profile TEXT PRIMARY KEY,revision INTEGER NOT NULL,value TEXT NOT NULL,imported INTEGER NOT NULL DEFAULT 0);CREATE TABLE IF NOT EXISTS product_settings_requests(profile TEXT NOT NULL,request TEXT NOT NULL,digest TEXT NOT NULL,response TEXT NOT NULL,PRIMARY KEY(profile,request));CREATE TABLE IF NOT EXISTS product_settings_worlds(world TEXT PRIMARY KEY);").map_err(|_|"storage_unavailable")
}
fn defaults() -> Value {
    json!({"locale":"zh-CN","residentPersona":DEFAULT_PERSONA,"backgroundTurnsPerHour":6,"autoSpeak":true,"autonomyEnabled":true,"agentBackend":"dsh","selectedWorldID":null,"defaultSpace":"living-pod","djHostPrompt":"","djTakeover":true,"djPlanningModel":null,"ttsProvider":"bailian","ttsModel":gmgn_voice_core::model_catalog::BAILIAN_TTS,"ttsVoice":"Cherry","asrProvider":"bailian","asrModel":gmgn_voice_core::model_catalog::BAILIAN_ASR,"microphoneDeviceID":null,"orbRed":0.16,"orbGreen":0.62,"orbBlue":1.0,"orbFlowIntensity":0.82,"remoteMotionCatalogURL":DEFAULT_MOTION_CATALOG,"shortcutAssignments":shortcut_defaults(),"globalShortcutsEnabled":true,"mediaKeysEnabled":true,"musicConnectedProviders":[],"avatarPositions":{},"stagePointCloudChoice":"automatic","stageParticleSizeMultiplier":1.0,"stageLegacyImported":false,"stageLyricsMode":"automatic","stageLyricsResolvedMode":"luminous","stageLyricsTrackID":null,"stageLyricsLegacyImported":false})
}
// Enum declaration order (cycle) differs from playbackModes (automatic hash).
const LYRICS_CYCLE: [&str; 12] = [
    "automatic",
    "luminous",
    "mindscape",
    "cloud_steps",
    "chorus_chat",
    "confession",
    "claddagh",
    "monet_poster",
    "article",
    "pendulum",
    "diorama",
    "folding_verse",
];
const LYRICS_PLAYBACK: [&str; 11] = [
    "luminous",
    "mindscape",
    "cloud_steps",
    "article",
    "chorus_chat",
    "confession",
    "claddagh",
    "monet_poster",
    "pendulum",
    "diorama",
    "folding_verse",
];
fn lyrics_mode(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|v| LYRICS_CYCLE.contains(v))
        .ok_or("product_settings_invalid_value")
}
fn resolve_lyrics(value: &mut Value) -> Result<()> {
    let mode = lyrics_mode(&value["stageLyricsMode"])?;
    let resolved = if mode == "automatic" {
        let track = value["stageLyricsTrackID"].as_str().unwrap_or("");
        let seed = track.bytes().fold(0u32, |seed, byte| {
            seed.wrapping_mul(31).wrapping_add(byte as u32) & 0x7fffffff
        });
        LYRICS_PLAYBACK[seed as usize % LYRICS_PLAYBACK.len()]
    } else {
        mode
    };
    value["stageLyricsResolvedMode"] = json!(resolved);
    Ok(())
}
const POSITION_PREFIX: &str = "ai.gmgn.radio.spatial.avatar-position.";
fn stage_scope(value: &Value) -> Result<&str> {
    let scope = short(value)?;
    if matches!(scope, "scene.dj_house" | "scene.cosy_wood_house")
        || scope
            .strip_prefix("world.")
            .is_some_and(|id| !id.is_empty())
    {
        Ok(scope)
    } else {
        Err("product_settings_invalid_value")
    }
}
fn stage_position(value: &Value) -> Result<Value> {
    let coordinates = value
        .as_array()
        .filter(|a| a.len() == 3)
        .ok_or("product_settings_invalid_value")?;
    if !coordinates.iter().all(|v| {
        v.as_f64()
            .is_some_and(|n| n.is_finite() && n.abs() <= f32::MAX as f64)
    }) {
        return Err("product_settings_invalid_value");
    }
    Ok(value.clone())
}
fn point_cloud(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|v| {
            [
                "automatic",
                "flowingCanvas",
                "orbitalShell",
                "openRibbon",
                "vinylRecord",
                "galaxyField",
                "tunnel",
                "void",
            ]
            .contains(v)
        })
        .ok_or("product_settings_invalid_value")
}
fn stage_event(value: &Value, event: &Value) -> Result<Value> {
    let mut next = value.clone();
    match event["kind"].as_str() {
        Some("avatarAxis") => {
            let scope = stage_scope(&event["scope"])?;
            let (axis, limit) = match event["axis"].as_str() {
                Some("X" | "x") => (0, 2.0),
                Some("Y" | "y") => (1, 2.0),
                Some("Z" | "z") => (2, 3.0),
                _ => return Err("product_settings_invalid_value"),
            };
            let coordinate = event["value"]
                .as_f64()
                .filter(|n| n.is_finite() && n.abs() <= limit)
                .ok_or("product_settings_invalid_value")?;
            let base = stage_position(&event["basePosition"])?;
            let mut position = if next["avatarPositions"][scope].is_null() {
                base
            } else {
                stage_position(&next["avatarPositions"][scope])?
            };
            position[axis] = json!(coordinate);
            next["avatarPositions"][scope] = position;
        }
        Some("avatarReset") => {
            let scope = stage_scope(&event["scope"])?;
            next["avatarPositions"]
                .as_object_mut()
                .ok_or("product_settings_invalid_state")?
                .remove(scope);
        }
        Some("pointCloud") => next["stagePointCloudChoice"] = json!(point_cloud(&event["value"])?),
        Some("particleSize") => {
            let size = event["value"]
                .as_f64()
                .filter(|n| n.is_finite())
                .ok_or("product_settings_invalid_value")?;
            next["stageParticleSizeMultiplier"] = json!(size.clamp(0.6, 1.6));
        }
        Some("lyricsSet") => next["stageLyricsMode"] = json!(lyrics_mode(&event["value"])?),
        Some("lyricsCycle") => {
            let index = LYRICS_CYCLE
                .iter()
                .position(|mode| Some(*mode) == next["stageLyricsMode"].as_str())
                .ok_or("product_settings_invalid_state")?;
            next["stageLyricsMode"] = json!(LYRICS_CYCLE[(index + 1) % LYRICS_CYCLE.len()]);
        }
        Some("lyricsTrack") => {
            next["stageLyricsTrackID"] = if event["trackID"].is_null() {
                Value::Null
            } else {
                json!(event["trackID"]
                    .as_str()
                    .filter(|s| s.len() <= 4096 && !s.contains('\0'))
                    .ok_or("product_settings_invalid_value")?)
            };
        }
        _ => return Err("product_settings_invalid_value"),
    }
    // A confirmed explicit stage edit must not later be overwritten by legacy input.
    if matches!(event["kind"].as_str(), Some("lyricsSet" | "lyricsCycle")) {
        next["stageLyricsLegacyImported"] = json!(true);
    } else if event["kind"] != "lyricsTrack" {
        next["stageLegacyImported"] = json!(true);
    }
    resolve_lyrics(&mut next)?;
    Ok(next)
}
fn stage_import(value: &Value, legacy: &Value) -> Result<Value> {
    if value["stageLegacyImported"] == true && value["stageLyricsLegacyImported"] == true {
        return Ok(value.clone());
    }
    let legacy = legacy
        .as_object()
        .filter(|o| o.len() <= 2048)
        .ok_or("product_settings_invalid_value")?;
    let mut next = value.clone();
    for (key, raw) in legacy {
        if key == "stage.lyrics.visualMode" {
            if value["stageLyricsLegacyImported"] != true {
                if let Ok(mode) = lyrics_mode(raw) {
                    next["stageLyricsMode"] = json!(mode);
                }
            }
        } else if let Some(scope) = key.strip_prefix(POSITION_PREFIX) {
            if value["stageLegacyImported"] == true {
                continue;
            }
            if stage_scope(&json!(scope)).is_ok()
                && stage_position(raw).is_ok()
                && next["avatarPositions"][scope].is_null()
            {
                next["avatarPositions"][scope] = raw.clone();
            }
        } else if key == "stage.point-cloud-choice" {
            if value["stageLegacyImported"] == true {
                continue;
            }
            if let Ok(choice) = point_cloud(raw) {
                next["stagePointCloudChoice"] = json!(choice);
            }
        } else if key == "stage.particle-size-multiplier" {
            if value["stageLegacyImported"] == true {
                continue;
            }
            if let Some(size) = raw.as_f64().filter(|n| n.is_finite()) {
                next["stageParticleSizeMultiplier"] = json!(size.clamp(0.6, 1.6));
            }
        } else {
            return Err("product_settings_unknown_field");
        }
    }
    next["stageLegacyImported"] = json!(true);
    next["stageLyricsLegacyImported"] = json!(true);
    resolve_lyrics(&mut next)?;
    Ok(next)
}
const ACTIONS: [&str; 8] = [
    "togglePlayback",
    "previousTrack",
    "nextTrack",
    "volumeUp",
    "volumeDown",
    "toggleVoice",
    "toggleStage",
    "toggleLyrics",
];
fn shortcut_defaults() -> Value {
    let local = [
        (49, "空格", 0),
        (123, "←", 1),
        (124, "→", 1),
        (126, "↑", 1),
        (125, "↓", 1),
        (46, "M", 1),
        (3, "F", 5),
        (15, "R", 1),
    ];
    let global = [
        (35, "P", 3),
        (123, "←", 3),
        (124, "→", 3),
        (126, "↑", 3),
        (125, "↓", 3),
        (46, "M", 3),
        (1, "S", 3),
        (15, "R", 3),
    ];
    let combo = |(code, label, flags)| json!({"keyCode":code,"keyLabel":label,"modifiers":flags});
    Value::Array(ACTIONS.iter().enumerate().map(|(i,name)|json!({"action":name,"local":combo(local[i]),"global":combo(global[i])})).collect())
}
fn combination(value: &Value) -> Result<Value> {
    let fields = value.as_object().ok_or("product_settings_invalid_value")?;
    if fields.len() != 3
        || value["keyCode"].as_u64().filter(|v| *v <= 65535).is_none()
        || value["modifiers"].as_u64().filter(|v| *v <= 15).is_none()
        || value["keyLabel"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 64 && !s.chars().any(char::is_control))
            .is_none()
    {
        return Err("product_settings_invalid_value");
    }
    Ok(value.clone())
}
fn assignments(value: &Value) -> Result<Value> {
    let a = value
        .as_array()
        .filter(|a| a.len() == 8)
        .ok_or("product_settings_invalid_value")?;
    let mut seen = std::collections::BTreeSet::new();
    for entry in a {
        let name = entry["action"]
            .as_str()
            .filter(|n| ACTIONS.contains(n))
            .ok_or("product_settings_invalid_value")?;
        if !seen.insert(name) || entry.as_object().filter(|o| o.len() == 3).is_none() {
            return Err("product_settings_invalid_value");
        }
        combination(&entry["local"])?;
        combination(&entry["global"])?;
    }
    Ok(value.clone())
}
fn music_providers(value: &Value) -> Result<Value> {
    let a = value
        .as_array()
        .filter(|a| a.len() <= 3)
        .ok_or("product_settings_invalid_value")?;
    let mut set = std::collections::BTreeSet::new();
    for p in a {
        let p = p
            .as_str()
            .filter(|p| ["netease", "qq-music", "apple-music"].contains(p))
            .ok_or("product_settings_invalid_value")?;
        if !set.insert(p) {
            return Err("product_settings_invalid_value");
        }
    }
    Ok(json!(set))
}
fn read(c: &Connection) -> Result<Value> {
    let row = c
        .query_row(
            "SELECT revision,value,imported FROM product_settings WHERE profile='product'",
            [],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, bool>(2)?,
                ))
            },
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    match row {
        None => Ok(json!({"revision":0,"values":defaults(),"imported":false})),
        Some((revision, value, imported)) => {
            let stored = serde_json::from_str::<Value>(&value)
                .map_err(|_| "product_settings_invalid_state")?;
            let mut complete = defaults();
            complete.as_object_mut().unwrap().extend(
                stored
                    .as_object()
                    .ok_or("product_settings_invalid_state")?
                    .clone(),
            );
            Ok(json!({"revision":revision,"values":complete,"imported":imported}))
        }
    }
}
fn short(value: &Value) -> Result<&str> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
        .ok_or("product_settings_invalid_value")
}
fn changes(c: &Connection, current: &Value, changes: &Value) -> Result<Value> {
    let fields = changes
        .as_object()
        .filter(|o| !o.is_empty() && o.len() <= 26)
        .ok_or("product_settings_invalid_value")?;
    let mut next = current
        .as_object()
        .ok_or("product_settings_invalid_state")?
        .clone();
    for (key, value) in fields {
        let v = match key.as_str() {
            "remoteMotionCatalogURL" => {
                let source = value
                    .as_str()
                    .ok_or("product_settings_invalid_value")?
                    .trim();
                let source = if source.is_empty()
                    || [
                        "http://127.0.0.1:8765/catalog.json",
                        "http://pancat-linux-ci.tail4c7fb9.ts.net:8765/catalog.json",
                        "http://100.110.226.64:8765/catalog.json",
                        "https://100.110.226.64:8765/catalog.json",
                    ]
                    .contains(&source)
                {
                    DEFAULT_MOTION_CATALOG
                } else {
                    source
                };
                let url =
                    reqwest::Url::parse(source).map_err(|_| "product_settings_invalid_value")?;
                let host = url.host_str().unwrap_or("");
                let allowed = url.scheme() == "https"
                    || (url.scheme() == "http"
                        && [
                            "localhost",
                            "127.0.0.1",
                            "[::1]",
                            "::1",
                            "192.168.1.85",
                            "100.110.226.64",
                            "pancat-linux-ci.tail4c7fb9.ts.net",
                        ]
                        .contains(&host));
                if !allowed {
                    return Err("product_settings_invalid_value");
                }
                json!(source)
            }
            "orbRed" | "orbGreen" | "orbBlue" | "orbFlowIntensity" => {
                let number = value
                    .as_f64()
                    .filter(|n| n.is_finite())
                    .ok_or("product_settings_invalid_value")?;
                json!(if key == "orbFlowIntensity" {
                    number.clamp(0.35, 1.5)
                } else {
                    number.clamp(0.0, 1.0)
                })
            }
            "defaultSpace" => {
                let id = short(value)?;
                if !["living-pod", "last-marble-world"].contains(&id) {
                    return Err("product_settings_invalid_value");
                }
                json!(id)
            }
            "locale" => {
                let id = short(value)?;
                if !["zh-CN", "en", "ja"].contains(&id) {
                    return Err("product_settings_invalid_locale");
                }
                json!(id)
            }
            "agentBackend" => {
                let id = short(value)?;
                if !["codex", "dsh", "claudeCode", "workbuddy", "qoder", "pi"].contains(&id) {
                    return Err("product_settings_invalid_backend");
                }
                json!(id)
            }
            "backgroundTurnsPerHour" => json!(value
                .as_i64()
                .ok_or("product_settings_invalid_value")?
                .clamp(0, 6)),
            "autoSpeak" | "autonomyEnabled" | "djTakeover" => {
                json!(value.as_bool().ok_or("product_settings_invalid_value")?)
            }
            "residentPersona" | "djHostPrompt" => {
                let text = value
                    .as_str()
                    .filter(|s| s.len() <= 32768 && !s.contains('\0'))
                    .ok_or("product_settings_invalid_value")?
                    .trim();
                json!(if text.is_empty() && key == "residentPersona" {
                    DEFAULT_PERSONA
                } else {
                    text
                })
            }
            "selectedWorldID" => {
                if value.is_null() {
                    Value::Null
                } else {
                    let id = short(value)?;
                    let found = c
                        .query_row(
                            "SELECT 1 FROM product_settings_worlds WHERE world=?1",
                            [id],
                            |_| Ok(()),
                        )
                        .optional()
                        .map_err(|_| "storage_unavailable")?
                        .is_some();
                    if !found {
                        return Err("product_settings_unknown_world");
                    }
                    json!(id)
                }
            }
            "djPlanningModel" | "microphoneDeviceID" => {
                if value.is_null() || value.as_str() == Some("") {
                    Value::Null
                } else {
                    json!(short(value)?)
                }
            }
            "ttsProvider" | "asrProvider" | "ttsModel" | "asrModel" | "ttsVoice" => {
                json!(short(value)?)
            }
            _ => return Err("product_settings_unknown_field"),
        };
        next.insert(key.clone(), v);
    }
    for (purpose, asr) in [("tts", false), ("asr", true)] {
        let provider = next[&format!("{purpose}Provider")]
            .as_str()
            .ok_or("product_settings_invalid_state")?;
        let model = next[&format!("{purpose}Model")]
            .as_str()
            .ok_or("product_settings_invalid_state")?;
        if !gmgn_voice_core::model_catalog::supports(provider, asr, model) {
            return Err("product_settings_invalid_model");
        }
    }
    let provider = next["ttsProvider"].as_str().unwrap();
    let model = next["ttsModel"].as_str().unwrap();
    let voice = next["ttsVoice"].as_str().unwrap();
    if provider == "bailian"
        && !gmgn_voice_core::model_catalog::bailian_voice_supported(model, voice)
    {
        return Err("product_settings_invalid_voice");
    }
    Ok(Value::Object(next))
}
// serde_json Map may preserve wire insertion order through workspace features.
// Journal identity ignores object key order, but preserves arrays and numbers.
fn canonical_json(value: &Value, output: &mut Vec<u8>) -> Result<()> {
    match value {
        Value::Object(fields) => {
            output.push(b'{');
            let mut keys: Vec<_> = fields.keys().collect();
            keys.sort();
            for (index, key) in keys.into_iter().enumerate() {
                if index != 0 {
                    output.push(b',');
                }
                serde_json::to_writer(&mut *output, key)
                    .map_err(|_| "product_settings_invalid_value")?;
                output.push(b':');
                canonical_json(&fields[key], output)?;
            }
            output.push(b'}');
        }
        Value::Array(items) => {
            output.push(b'[');
            for (index, item) in items.iter().enumerate() {
                if index != 0 {
                    output.push(b',');
                }
                canonical_json(item, output)?;
            }
            output.push(b']');
        }
        _ => serde_json::to_writer(output, value).map_err(|_| "product_settings_invalid_value")?,
    }
    Ok(())
}

pub fn request(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    match method {
        "product_settings_read" => read(c),
        "product_settings_bind_catalog" => {
            let worlds = p["worldIDs"]
                .as_array()
                .filter(|a| a.len() <= 1024)
                .ok_or("product_settings_invalid_catalog")?;
            let ids: std::collections::BTreeSet<String> = worlds
                .iter()
                .map(|v| short(v).map(str::to_owned))
                .collect::<Result<_>>()?;
            if ids.len() != worlds.len() {
                return Err("product_settings_invalid_catalog");
            }
            let tx = c.transaction().map_err(|_| "storage_unavailable")?;
            tx.execute("DELETE FROM product_settings_worlds", [])
                .map_err(|_| "storage_unavailable")?;
            for id in ids {
                tx.execute(
                    "INSERT INTO product_settings_worlds(world) VALUES(?1)",
                    [id],
                )
                .map_err(|_| "storage_unavailable")?;
            }
            tx.commit().map_err(|_| "storage_unavailable")?;
            read(c)
        }
        "product_settings_import" => {
            let prior = read(c)?;
            if prior["imported"] == true {
                return Ok(prior);
            }
            let legacy = p
                .get("values")
                .and_then(Value::as_object)
                .ok_or("product_settings_invalid_value")?;
            let mut legacy = legacy.clone();
            let shortcut = legacy
                .remove("shortcutAssignments")
                .map(|v| assignments(&v))
                .transpose()?;
            let global = legacy
                .remove("globalShortcutsEnabled")
                .map(|v| v.as_bool().ok_or("product_settings_invalid_value"))
                .transpose()?;
            let media = legacy
                .remove("mediaKeysEnabled")
                .map(|v| v.as_bool().ok_or("product_settings_invalid_value"))
                .transpose()?;
            let music = legacy
                .remove("musicConnectedProviders")
                .map(|v| music_providers(&v))
                .transpose()?;
            let mut value = if legacy.is_empty() {
                prior["values"].clone()
            } else {
                changes(c, &prior["values"], &Value::Object(legacy))?
            };
            if let Some(v) = shortcut {
                value["shortcutAssignments"] = v;
            }
            if let Some(v) = global {
                value["globalShortcutsEnabled"] = json!(v);
            }
            if let Some(v) = media {
                value["mediaKeysEnabled"] = json!(v);
            }
            if let Some(v) = music {
                value["musicConnectedProviders"] = v;
            }
            let revision = prior["revision"]
                .as_i64()
                .ok_or("product_settings_invalid_state")?
                .checked_add(1)
                .ok_or("product_settings_invalid_state")?;
            c.execute("INSERT INTO product_settings(profile,revision,value,imported) VALUES('product',?1,?2,1) ON CONFLICT(profile) DO UPDATE SET revision=excluded.revision,value=excluded.value,imported=1",params![revision,value.to_string()]).map_err(|_|"storage_unavailable")?;
            read(c)
        }
        "product_settings_apply"
        | "product_settings_shortcut_event"
        | "product_settings_music_receipt"
        | "product_settings_stage_event"
        | "product_settings_stage_import" => {
            let id = short(&p["requestID"])?;
            let mut canonical = Vec::new();
            canonical_json(&json!([method, p]), &mut canonical)?;
            let digest = format!("{:x}", Sha256::digest(canonical));
            let old=c.query_row("SELECT digest,response FROM product_settings_requests WHERE profile='product' AND request=?1",[id],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).optional().map_err(|_|"storage_unavailable")?;
            if let Some((hash, response)) = old {
                if hash != digest {
                    return Err("product_settings_request_conflict");
                }
                return serde_json::from_str(&response)
                    .map_err(|_| "product_settings_invalid_state");
            }
            let before = read(c)?;
            let revision = before["revision"]
                .as_i64()
                .ok_or("product_settings_invalid_state")?;
            if p["expectedRevision"].as_i64() != Some(revision) {
                return Err("product_settings_revision_conflict");
            }
            let value = if method == "product_settings_apply" {
                changes(c, &before["values"], &p["changes"])?
            } else if method == "product_settings_stage_event" {
                stage_event(&before["values"], &p["event"])?
            } else if method == "product_settings_stage_import" {
                stage_import(&before["values"], &p["legacy"])?
            } else if method == "product_settings_music_receipt" {
                let provider = p["providerID"]
                    .as_str()
                    .filter(|p| ["netease", "qq-music", "apple-music"].contains(p))
                    .ok_or("product_settings_invalid_value")?;
                let connected = p["connected"]
                    .as_bool()
                    .ok_or("product_settings_invalid_value")?;
                let mut value = before["values"].clone();
                let providers = music_providers(&value["musicConnectedProviders"])?;
                let mut set: std::collections::BTreeSet<String> = providers
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap().to_owned())
                    .collect();
                if connected {
                    set.insert(provider.to_owned());
                } else {
                    set.remove(provider);
                }
                value["musicConnectedProviders"] = json!(set);
                value
            } else {
                let mut value = before["values"].clone();
                let event = &p["event"];
                match event["kind"].as_str() {
                    Some("reset") => value["shortcutAssignments"] = shortcut_defaults(),
                    Some("globalEnabled") | Some("mediaKeysEnabled") => {
                        let key = if event["kind"] == "globalEnabled" {
                            "globalShortcutsEnabled"
                        } else {
                            "mediaKeysEnabled"
                        };
                        value[key] = json!(event["enabled"]
                            .as_bool()
                            .ok_or("product_settings_invalid_value")?);
                    }
                    Some("assign") => {
                        let action = event["action"]
                            .as_str()
                            .filter(|n| ACTIONS.contains(n))
                            .ok_or("product_settings_invalid_value")?;
                        let scope = event["scope"]
                            .as_str()
                            .filter(|s| ["local", "global"].contains(s))
                            .ok_or("product_settings_invalid_value")?;
                        let new = combination(&event["combination"])?;
                        let mut a = assignments(&value["shortcutAssignments"])?;
                        let entries = a.as_array_mut().unwrap();
                        let target = entries.iter().position(|e| e["action"] == action).unwrap();
                        let old = entries[target][scope].clone();
                        if let Some(other) = entries.iter().position(|e| {
                            e["action"] != action
                                && e[scope]["keyCode"] == new["keyCode"]
                                && e[scope]["modifiers"] == new["modifiers"]
                        }) {
                            entries[other][scope] = old;
                        }
                        entries[target][scope] = new;
                        value["shortcutAssignments"] = a;
                    }
                    _ => return Err("product_settings_invalid_value"),
                }
                value
            };
            let revision = revision
                .checked_add(1)
                .ok_or("product_settings_invalid_state")?;
            let imported = if matches!(
                method,
                "product_settings_stage_event" | "product_settings_stage_import"
            ) {
                before["imported"]
                    .as_bool()
                    .ok_or("product_settings_invalid_state")?
            } else {
                true
            };
            let response = json!({"revision":revision,"values":value,"imported":imported});
            let tx = c.transaction().map_err(|_| "storage_unavailable")?;
            tx.execute("INSERT INTO product_settings(profile,revision,value,imported) VALUES('product',?1,?2,?3) ON CONFLICT(profile) DO UPDATE SET revision=excluded.revision,value=excluded.value,imported=excluded.imported",params![revision,value.to_string(),imported]).map_err(|_|"storage_unavailable")?;
            tx.execute("INSERT INTO product_settings_requests(profile,request,digest,response) VALUES('product',?1,?2,?3)",params![id,digest,response.to_string()]).map_err(|_|"storage_unavailable")?;
            tx.commit().map_err(|_| "storage_unavailable")?;
            Ok(response)
        }
        _ => Err("unsupported_method"),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn journal_canonicalizes_nested_wire_keys_but_not_content_or_method() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let first: Value = serde_json::from_str(r#"{"requestID":"key-order","expectedRevision":0,"event":{"kind":"avatarAxis","scope":"scene.dj_house","axis":"x","value":0.5,"basePosition":[0,1,-0.58]}}"#).unwrap();
        let reordered: Value = serde_json::from_str(r#"{"event":{"basePosition":[0,1,-0.58],"value":0.5,"axis":"x","scope":"scene.dj_house","kind":"avatarAxis"},"expectedRevision":0,"requestID":"key-order"}"#).unwrap();
        let output = request(&mut c, "product_settings_stage_event", &first).unwrap();
        assert_eq!(
            request(&mut c, "product_settings_stage_event", &reordered).unwrap(),
            output
        );
        assert_eq!(read(&c).unwrap()["revision"], 1);
        assert_eq!(
            c.query_row("SELECT count(*) FROM product_settings_requests", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
            1
        );
        let mut changed = reordered.clone();
        changed["event"]["basePosition"] = json!([1, 0, -0.58]);
        assert_eq!(
            request(&mut c, "product_settings_stage_event", &changed),
            Err("product_settings_request_conflict")
        );
        assert_eq!(
            request(&mut c, "product_settings_apply", &reordered),
            Err("product_settings_request_conflict")
        );
        assert_eq!(read(&c).unwrap(), output);
        // Numeric representation is deliberately not silently widened.
        let mut integer = reordered.clone();
        integer["event"]["value"] = json!(1);
        let mut float = integer.clone();
        float["event"]["value"] = json!(1.0);
        let mut a = Vec::new();
        let mut b = Vec::new();
        canonical_json(&integer, &mut a).unwrap();
        canonical_json(&float, &mut b).unwrap();
        assert_ne!(a, b);
    }
    fn stage(c: &mut Connection, id: &str, event: Value) -> Result<Value> {
        let before = read(c)?;
        request(
            c,
            "product_settings_stage_event",
            &json!({"requestID":id,"expectedRevision":before["revision"],"event":event}),
        )
    }
    #[test]
    fn stage_axis_scope_reset_cloud_particle_rules_are_sql_authoritative() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let x=stage(&mut c,"x",json!({"kind":"avatarAxis","scope":"scene.dj_house","axis":"x","value":1.5,"basePosition":[-0.72,0,-0.58]})).unwrap();
        assert_eq!(
            x["values"]["avatarPositions"]["scene.dj_house"],
            json!([1.5, 0, -0.58])
        );
        let y=stage(&mut c,"y",json!({"kind":"avatarAxis","scope":"scene.dj_house","axis":"Y","value":-2.0,"basePosition":[99,99,99]})).unwrap();
        assert_eq!(
            y["values"]["avatarPositions"]["scene.dj_house"],
            json!([1.5, -2.0, -0.58])
        );
        stage(&mut c,"world",json!({"kind":"avatarAxis","scope":"world.private-world","axis":"Z","value":3.0,"basePosition":[7,8,9]})).unwrap();
        for (id, event) in [
            (
                "range",
                json!({"kind":"avatarAxis","scope":"scene.dj_house","axis":"X","value":2.001,"basePosition":[0,0,0]}),
            ),
            (
                "scope",
                json!({"kind":"avatarReset","scope":"scene.unknown"}),
            ),
            (
                "axis",
                json!({"kind":"avatarAxis","scope":"scene.dj_house","axis":"Q","value":0,"basePosition":[0,0,0]}),
            ),
            (
                "base",
                json!({"kind":"avatarAxis","scope":"scene.dj_house","axis":"X","value":0,"basePosition":[0,0]}),
            ),
            ("cloud", json!({"kind":"pointCloud","value":"not-a-cloud"})),
        ] {
            let before = read(&c).unwrap();
            assert_eq!(
                stage(&mut c, id, event),
                Err("product_settings_invalid_value")
            );
            assert_eq!(read(&c).unwrap(), before);
        }
        let reset = stage(
            &mut c,
            "reset",
            json!({"kind":"avatarReset","scope":"scene.dj_house"}),
        )
        .unwrap();
        assert!(reset["values"]["avatarPositions"]["scene.dj_house"].is_null());
        assert_eq!(
            reset["values"]["avatarPositions"]["world.private-world"],
            json!([7, 8, 3.0])
        );
        assert_eq!(
            stage(&mut c, "tiny", json!({"kind":"particleSize","value":-10})).unwrap()["values"]
                ["stageParticleSizeMultiplier"],
            0.6
        );
        assert_eq!(
            stage(&mut c, "huge", json!({"kind":"particleSize","value":10})).unwrap()["values"]
                ["stageParticleSizeMultiplier"],
            1.6
        );
        for choice in [
            "automatic",
            "flowingCanvas",
            "orbitalShell",
            "openRibbon",
            "vinylRecord",
            "galaxyField",
            "tunnel",
            "void",
        ] {
            assert_eq!(
                stage(&mut c, choice, json!({"kind":"pointCloud","value":choice})).unwrap()
                    ["values"]["stagePointCloudChoice"],
                choice
            );
        }
        let before = read(&c).unwrap();
        assert_eq!(
            request(
                &mut c,
                "product_settings_apply",
                &json!({"requestID":"bypass","expectedRevision":before["revision"],"changes":{"avatarPositions":{"scene.dj_house":[9,9,9]}}})
            ),
            Err("product_settings_unknown_field")
        );
    }
    #[test]
    fn stage_legacy_once_and_global_import_orders_preserve_confirmed_values() {
        for global_first in [false, true] {
            let mut c = Connection::open_in_memory().unwrap();
            schema(&c).unwrap();
            let global = json!({"values":{"locale":"ja","autoSpeak":false}});
            if global_first {
                request(&mut c, "product_settings_import", &global).unwrap();
            }
            let before = read(&c).unwrap();
            let p = json!({"requestID":"legacy-stage","expectedRevision":before["revision"],"legacy":{"ai.gmgn.radio.spatial.avatar-position.scene.dj_house":[1,2,3],"ai.gmgn.radio.spatial.avatar-position.scene.unknown":[4,5,6],"stage.point-cloud-choice":"vinylRecord","stage.particle-size-multiplier":99}});
            let imported = request(&mut c, "product_settings_stage_import", &p).unwrap();
            assert_eq!(
                request(&mut c, "product_settings_stage_import", &p).unwrap(),
                imported
            );
            assert_eq!(
                request(&mut c, "product_settings_stage_event", &p),
                Err("product_settings_request_conflict")
            );
            if !global_first {
                request(&mut c, "product_settings_import", &global).unwrap();
            }
            let result = read(&c).unwrap();
            assert_eq!(result["values"]["locale"], "ja");
            assert_eq!(result["values"]["autoSpeak"], false);
            assert_eq!(result["values"]["stagePointCloudChoice"], "vinylRecord");
            assert_eq!(result["values"]["stageParticleSizeMultiplier"], 1.6);
            assert!(result["values"]["avatarPositions"]["scene.unknown"].is_null());
            let again=request(&mut c,"product_settings_stage_import",&json!({"requestID":"late","expectedRevision":result["revision"],"legacy":{"stage.point-cloud-choice":"tunnel"}})).unwrap();
            assert_eq!(again["values"], result["values"]);
            let chosen =
                stage(&mut c, "user", json!({"kind":"pointCloud","value":"void"})).unwrap();
            assert_eq!(
                request(
                    &mut c,
                    "product_settings_import",
                    &json!({"values":{"locale":"en"}})
                )
                .unwrap(),
                chosen
            );
        }
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let edited = stage(
            &mut c,
            "first-user",
            json!({"kind":"pointCloud","value":"void"}),
        )
        .unwrap();
        let late=request(&mut c,"product_settings_stage_import",&json!({"requestID":"late","expectedRevision":edited["revision"],"legacy":{"stage.point-cloud-choice":"tunnel"}})).unwrap();
        assert_eq!(late["values"]["stagePointCloudChoice"], "void");
    }
    #[test]
    fn stage_receipt_loss_sql_reopen_and_revision_errors_do_not_reapply() {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let file = std::env::temp_dir().join(format!(
            "gmgn-stage-settings-{nonce}-{}.sqlite",
            std::process::id()
        ));
        let p = json!({"requestID":"lost","expectedRevision":0,"event":{"kind":"avatarAxis","scope":"scene.cosy_wood_house","axis":"Z","value":-3,"basePosition":[0,0,-0.58]}});
        let response = {
            let mut c = Connection::open(&file).unwrap();
            schema(&c).unwrap();
            request(&mut c, "product_settings_stage_event", &p).unwrap()
        };
        let mut reopened = Connection::open(&file).unwrap();
        schema(&reopened).unwrap();
        assert_eq!(read(&reopened).unwrap(), response);
        assert_eq!(
            request(&mut reopened, "product_settings_stage_event", &p).unwrap(),
            response
        );
        let mut changed = p.clone();
        changed["event"]["value"] = json!(0);
        assert_eq!(
            request(&mut reopened, "product_settings_stage_event", &changed),
            Err("product_settings_request_conflict")
        );
        changed["requestID"] = json!("stale");
        assert_eq!(
            request(&mut reopened, "product_settings_stage_event", &changed),
            Err("product_settings_revision_conflict")
        );
        assert_eq!(read(&reopened).unwrap(), response);
        drop(reopened);
        std::fs::remove_file(file).unwrap();
    }
    #[test]
    fn lyrics_mode_cycle_track_hash_and_separate_legacy_marker_are_authoritative() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let prior = stage(
            &mut c,
            "cloud-first",
            json!({"kind":"pointCloud","value":"void"}),
        )
        .unwrap();
        assert_eq!(prior["values"]["stageLegacyImported"], true);
        assert_eq!(prior["values"]["stageLyricsLegacyImported"], false);
        let p = json!({"requestID":"old-lyrics","expectedRevision":prior["revision"],"legacy":{"stage.lyrics.visualMode":"monet_poster","stage.point-cloud-choice":"tunnel"}});
        let imported = request(&mut c, "product_settings_stage_import", &p).unwrap();
        assert_eq!(imported["values"]["stageLyricsMode"], "monet_poster");
        assert_eq!(
            imported["values"]["stageLyricsResolvedMode"],
            "monet_poster"
        );
        assert_eq!(imported["values"]["stagePointCloudChoice"], "void");
        assert_eq!(
            stage(&mut c, "cycle-to-article", json!({"kind":"lyricsCycle"})).unwrap()["values"]
                ["stageLyricsMode"],
            "article"
        );
        stage(
            &mut c,
            "manual",
            json!({"kind":"lyricsSet","value":"folding_verse"}),
        )
        .unwrap();
        assert_eq!(
            stage(
                &mut c,
                "manual-track",
                json!({"kind":"lyricsTrack","trackID":"track-c"})
            )
            .unwrap()["values"]["stageLyricsResolvedMode"],
            "folding_verse"
        );
        let auto = stage(&mut c, "cycle-to-auto", json!({"kind":"lyricsCycle"})).unwrap();
        assert_eq!(auto["values"]["stageLyricsMode"], "automatic");
        assert_eq!(auto["values"]["stageLyricsResolvedMode"], "cloud_steps");
        for (track, resolved) in [
            ("", "luminous"),
            ("track-b", "mindscape"),
            ("track-d", "article"),
            ("中文🎵", "luminous"),
        ] {
            let result = stage(
                &mut c,
                &format!("track-event-{track}"),
                json!({"kind":"lyricsTrack","trackID":track}),
            )
            .unwrap();
            assert_eq!(result["values"]["stageLyricsResolvedMode"], resolved);
            assert_eq!(result["values"]["stageLyricsTrackID"], track);
        }
        let nil = stage(&mut c, "nil", json!({"kind":"lyricsTrack","trackID":null})).unwrap();
        assert_eq!(nil["values"]["stageLyricsResolvedMode"], "luminous");
        let before = read(&c).unwrap();
        assert_eq!(
            stage(
                &mut c,
                "bad-mode",
                json!({"kind":"lyricsSet","value":"not-a-mode"})
            ),
            Err("product_settings_invalid_value")
        );
        assert_eq!(
            stage(
                &mut c,
                "bad-track",
                json!({"kind":"lyricsTrack","trackID":9})
            ),
            Err("product_settings_invalid_value")
        );
        assert_eq!(read(&c).unwrap(), before);
    }
    #[test]
    fn shortcut_events_swap_conflicts_reset_and_deduplicate() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let original = read(&c).unwrap();
        let new = original["values"]["shortcutAssignments"][1]["local"].clone();
        let p = json!({"requestID":"assign","expectedRevision":0,"event":{"kind":"assign","action":"togglePlayback","scope":"local","combination":new}});
        let response = request(&mut c, "product_settings_shortcut_event", &p).unwrap();
        assert_eq!(response["values"]["shortcutAssignments"][0]["local"], new);
        assert_eq!(
            response["values"]["shortcutAssignments"][1]["local"],
            original["values"]["shortcutAssignments"][0]["local"]
        );
        assert_eq!(
            request(&mut c, "product_settings_shortcut_event", &p).unwrap(),
            response
        );
        assert_eq!(
            request(&mut c, "product_settings_apply", &p),
            Err("product_settings_request_conflict")
        );
        let disabled=request(&mut c,"product_settings_shortcut_event",&json!({"requestID":"disable","expectedRevision":1,"event":{"kind":"globalEnabled","enabled":false}})).unwrap();
        assert_eq!(disabled["values"]["globalShortcutsEnabled"], false);
        let reset = request(
            &mut c,
            "product_settings_shortcut_event",
            &json!({"requestID":"reset","expectedRevision":2,"event":{"kind":"reset"}}),
        )
        .unwrap();
        assert_eq!(reset["values"]["shortcutAssignments"], shortcut_defaults());
        assert_eq!(reset["values"]["globalShortcutsEnabled"], false);
        assert_eq!(
            request(
                &mut c,
                "product_settings_shortcut_event",
                &json!({"requestID":"bad","expectedRevision":3,"event":{"kind":"assign","action":"togglePlayback","scope":"local","combination":{"keyCode":70000,"keyLabel":"X","modifiers":0}}})
            ),
            Err("product_settings_invalid_value")
        );
        assert_eq!(read(&c).unwrap(), reset);
    }
    #[test]
    fn music_facts_require_private_receipt_and_import_is_once_only() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let imported=request(&mut c,"product_settings_import",&json!({"values":{"musicConnectedProviders":["qq-music"],"shortcutAssignments":shortcut_defaults(),"mediaKeysEnabled":false}})).unwrap();
        assert_eq!(
            imported["values"]["musicConnectedProviders"],
            json!(["qq-music"])
        );
        assert_eq!(
            request(
                &mut c,
                "product_settings_apply",
                &json!({"requestID":"fake","expectedRevision":1,"changes":{"musicConnectedProviders":["netease"]}})
            ),
            Err("product_settings_unknown_field")
        );
        let p = json!({"requestID":"connect","expectedRevision":1,"providerID":"netease","connected":true});
        let connected = request(&mut c, "product_settings_music_receipt", &p).unwrap();
        assert_eq!(
            connected["values"]["musicConnectedProviders"],
            json!(["netease", "qq-music"])
        );
        assert_eq!(
            request(&mut c, "product_settings_music_receipt", &p).unwrap(),
            connected
        );
        let disconnected=request(&mut c,"product_settings_music_receipt",&json!({"requestID":"disconnect","expectedRevision":2,"providerID":"qq-music","connected":false})).unwrap();
        assert_eq!(
            disconnected["values"]["musicConnectedProviders"],
            json!(["netease"])
        );
        assert_eq!(
            request(
                &mut c,
                "product_settings_import",
                &json!({"values":{"musicConnectedProviders":["qq-music"]}})
            )
            .unwrap(),
            disconnected
        );
        assert_eq!(
            request(
                &mut c,
                "product_settings_music_receipt",
                &json!({"requestID":"stale","expectedRevision":1,"providerID":"apple-music","connected":true})
            ),
            Err("product_settings_revision_conflict")
        );
    }
    #[test]
    fn authority_rejects_secrets_and_persists_confirmed_atomic_choices() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        request(&mut c, "product_settings_import", &json!({"values":{}})).unwrap();
        let bad = json!({"requestID":"a","expectedRevision":1,"changes":{"apiKey":"private-inert-fixture"}});
        assert_eq!(
            request(&mut c, "product_settings_apply", &bad),
            Err("product_settings_unknown_field")
        );
        assert!(!read(&c)
            .unwrap()
            .to_string()
            .contains("private-inert-fixture"));
        let ok = json!({"requestID":"b","expectedRevision":1,"changes":{"locale":"ja","residentPersona":" custom ","backgroundTurnsPerHour":20}});
        let result = request(&mut c, "product_settings_apply", &ok).unwrap();
        assert_eq!(result["values"]["backgroundTurnsPerHour"], 6);
        assert_eq!(result["values"]["residentPersona"], "custom");
        assert_eq!(
            request(&mut c, "product_settings_apply", &ok).unwrap(),
            result
        );
        assert_eq!(
            request(
                &mut c,
                "product_settings_apply",
                &json!({"requestID":"c","expectedRevision":1,"changes":{"autoSpeak":false}})
            ),
            Err("product_settings_revision_conflict")
        );
        assert_eq!(
            request(
                &mut c,
                "product_settings_import",
                &json!({"values":{"locale":"en"}})
            )
            .unwrap(),
            result
        );
    }
    #[test]
    fn orb_numeric_bounds_are_rust_owned_and_old_profiles_gain_defaults() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let initial = defaults();
        let mut legacy = initial.clone();
        for key in ["orbRed", "orbGreen", "orbBlue", "orbFlowIntensity"] {
            legacy.as_object_mut().unwrap().remove(key);
        }
        c.execute("INSERT INTO product_settings(profile,revision,value,imported) VALUES('product',4,?1,1)",[legacy.to_string()]).unwrap();
        assert_eq!(read(&c).unwrap()["values"]["orbFlowIntensity"], 0.82);
        let response=request(&mut c,"product_settings_apply",&json!({"requestID":"orb","expectedRevision":4,"changes":{"orbRed":1.7,"orbGreen":-0.4,"orbBlue":0.48,"orbFlowIntensity":2.3}})).unwrap();
        assert_eq!(response["values"]["orbRed"], 1.0);
        assert_eq!(response["values"]["orbGreen"], 0.0);
        assert_eq!(response["values"]["orbBlue"], 0.48);
        assert_eq!(response["values"]["orbFlowIntensity"], 1.5);
        assert_eq!(
            request(
                &mut c,
                "product_settings_apply",
                &json!({"requestID":"bad-orb","expectedRevision":5,"changes":{"orbRed":"red"}})
            ),
            Err("product_settings_invalid_value")
        );
        assert_eq!(read(&c).unwrap(), response);
    }
    #[test]
    fn remote_motion_catalog_preserves_legacy_resolution_and_existing_url_policy() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let response = request(
            &mut c,
            "product_settings_import",
            &json!({"values":{"remoteMotionCatalogURL":"http://127.0.0.1:8765/catalog.json"}}),
        )
        .unwrap();
        assert_eq!(
            response["values"]["remoteMotionCatalogURL"],
            DEFAULT_MOTION_CATALOG
        );
        for (index, url) in [
            "https://catalog.example/motions.json",
            "http://localhost:8765/other.json",
            "http://192.168.1.85:8765/other.json",
            "http://[::1]:8765/catalog.json",
        ]
        .into_iter()
        .enumerate()
        {
            let revision = read(&c).unwrap()["revision"].clone();
            assert_eq!(request(&mut c,"product_settings_apply",&json!({"requestID":format!("catalog-{index}"),"expectedRevision":revision,"changes":{"remoteMotionCatalogURL":url}})).unwrap()["values"]["remoteMotionCatalogURL"],url);
        }
        let before = read(&c).unwrap();
        assert_eq!(
            request(
                &mut c,
                "product_settings_apply",
                &json!({"requestID":"bad-catalog","expectedRevision":before["revision"],"changes":{"remoteMotionCatalogURL":"http://public.example/catalog.json"}})
            ),
            Err("product_settings_invalid_value")
        );
        assert_eq!(read(&c).unwrap(), before);
    }
    #[test]
    fn exact_model_voice_and_world_catalog_are_required() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let apply = |c: &mut Connection, changes: Value| {
            request(
                c,
                "product_settings_apply",
                &json!({"requestID":"test","expectedRevision":0,"changes":changes}),
            )
        };
        assert_eq!(
            apply(&mut c, json!({"selectedWorldID":"missing"})),
            Err("product_settings_unknown_world")
        );
        assert_eq!(
            apply(&mut c, json!({"ttsProvider":"fish"})),
            Err("product_settings_invalid_model")
        );
        assert_eq!(
            apply(&mut c, json!({"ttsVoice":"fake"})),
            Err("product_settings_invalid_voice")
        );
        request(
            &mut c,
            "product_settings_bind_catalog",
            &json!({"worldIDs":["world"]}),
        )
        .unwrap();
        assert_eq!(apply(&mut c,json!({"selectedWorldID":"world","ttsProvider":"fish","ttsModel":"s2.1-pro-free","ttsVoice":"actual-reference"})).unwrap()["values"]["selectedWorldID"],"world");
    }

    /// One authority, two revision caches: the stale cache is refused, and a cache
    /// that tracks the revision it was handed writes consecutively. This is the
    /// real-machine `product_settings_revision_conflict`: `UnityMediaHost` wrote
    /// through two `RustProductSettingsClient` instances on one `tasks.sqlite3`.
    #[test]
    fn a_second_revision_cache_on_one_authority_is_refused() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        request(&mut c, "product_settings_import", &json!({"values":{}})).unwrap();
        let mut cache_a = read(&c).unwrap()["revision"].as_i64().unwrap();
        let cache_b = cache_a;
        assert_eq!(cache_a, 1);
        let first = request(&mut c, "product_settings_apply", &json!({"requestID":"a","expectedRevision":cache_a,"changes":{"locale":"ja"}})).unwrap();
        cache_a = first["revision"].as_i64().unwrap();
        assert_eq!(cache_a, 2);
        assert_eq!(
            request(&mut c, "product_settings_apply", &json!({"requestID":"b","expectedRevision":cache_b,"changes":{"autoSpeak":false}})),
            Err("product_settings_revision_conflict")
        );
        // One cache per authority: the writer reads back the revision it was handed
        // and two consecutive settings writes both land.
        let cache_b = read(&c).unwrap()["revision"].as_i64().unwrap();
        let second = request(&mut c, "product_settings_apply", &json!({"requestID":"b","expectedRevision":cache_b,"changes":{"autoSpeak":false}})).unwrap();
        assert_eq!(second["revision"], cache_b + 1);
        let third = request(&mut c, "product_settings_apply", &json!({"requestID":"c","expectedRevision":second["revision"],"changes":{"locale":"en"}})).unwrap();
        assert_eq!(third["revision"], second["revision"].as_i64().unwrap() + 1);
    }
}
