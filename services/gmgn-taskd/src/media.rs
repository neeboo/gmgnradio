//! Public video cache and playback lists. Signed source URLs never enter SQLite.
//! Files and metadata belong to the same taskd authority, not the UI process.
use crate::{files, model::Result, store::Database};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt},
    sync::{watch, Mutex},
};

const ITEM_LIMIT: u64 = 512 * 1024 * 1024;
const CACHE_LIMIT: u64 = 2 * 1024 * 1024 * 1024;
const RANGE_BYTES: u64 = 1024 * 1024;
const HELPER_OUTPUT_LIMIT: usize = 4 * 1024 * 1024;
const MAX_LIST_ITEMS: usize = 200;

#[derive(Clone)]
pub struct Helpers {
    pub helper: PathBuf,
    pub helper_sha256: String,
    pub deno: PathBuf,
    pub deno_sha256: String,
}

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE media_cache(cache_key TEXT PRIMARY KEY,page_url TEXT NOT NULL,height INTEGER NOT NULL,state TEXT NOT NULL,payload TEXT NOT NULL,bytes INTEGER NOT NULL DEFAULT 0,last_used INTEGER NOT NULL,error TEXT);
        CREATE TABLE video_playlists(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,current_index INTEGER NOT NULL,payload TEXT NOT NULL);
        CREATE INDEX media_cache_lru ON media_cache(last_used,cache_key);").map_err(|_| "storage_unavailable")
}

#[derive(Clone)]
struct Entry {
    key: String,
    page: String,
    height: u32,
}
struct Mp4SegmentIndex {
    first_offset: u64,
    segments: Vec<(u64, u64, f64)>,
}
fn mp4_segment_index(bytes: &[u8]) -> Result<Option<Mp4SegmentIndex>> {
    let u32_at = |at: usize| -> Result<u32> {
        Ok(u32::from_be_bytes(
            bytes
                .get(at..at + 4)
                .ok_or("media_invalid_content")?
                .try_into()
                .map_err(|_| "media_invalid_content")?,
        ))
    };
    let u64_at = |at: usize| -> Result<u64> {
        Ok(u64::from_be_bytes(
            bytes
                .get(at..at + 8)
                .ok_or("media_invalid_content")?
                .try_into()
                .map_err(|_| "media_invalid_content")?,
        ))
    };
    let mut at = 0usize;
    while at + 8 <= bytes.len() {
        let size = u32_at(at)? as usize;
        if size < 8 {
            return Ok(None);
        }
        if &bytes[at + 4..at + 8] == b"sidx" {
            if size < 32 || at.checked_add(size).is_none_or(|end| end > bytes.len()) {
                return Err("media_invalid_content");
            }
            let version = bytes[at + 8];
            let scale = u32_at(at + 16)?;
            if scale == 0 {
                return Err("media_invalid_content");
            }
            let (first, count_at) = match version {
                0 => (u32_at(at + 24)? as u64, at + 30),
                1 if size >= 40 => (u64_at(at + 28)?, at + 38),
                _ => return Err("media_invalid_content"),
            };
            let count = u16::from_be_bytes(
                bytes
                    .get(count_at..count_at + 2)
                    .ok_or("media_invalid_content")?
                    .try_into()
                    .map_err(|_| "media_invalid_content")?,
            ) as usize;
            if count == 0 || count > 2048 || count_at + 2 + count * 12 > at + size {
                return Err("media_invalid_content");
            }
            let first_offset = ((at + size) as u64)
                .checked_add(first)
                .filter(|offset| *offset > 0)
                .ok_or("media_invalid_content")?;
            let mut offset = first_offset;
            let mut segments = Vec::with_capacity(count);
            for n in 0..count {
                let ref_at = count_at + 2 + n * 12;
                let reference = u32_at(ref_at)?;
                let duration = u32_at(ref_at + 4)?;
                if reference & 0x80000000 != 0
                    || reference == 0
                    || reference as u64 > 16 * 1024 * 1024
                    || duration == 0
                {
                    return Err("media_unsupported_format");
                }
                let length = reference as u64;
                segments.push((offset, length, duration as f64 / scale as f64));
                offset = offset.checked_add(length).ok_or("media_invalid_content")?;
            }
            return Ok(Some(Mp4SegmentIndex {
                first_offset,
                segments,
            }));
        }
        if &bytes[at + 4..at + 8] == b"mdat" {
            return Ok(None);
        }
        let Some(next) = at.checked_add(size) else {
            return Err("media_invalid_content");
        };
        if next > bytes.len() {
            return Err("media_unsupported_format");
        }
        at = next;
    }
    Ok(None)
}

fn entry(v: &Value) -> Result<Entry> {
    let raw = v["pageURL"].as_str().ok_or("invalid_media_input")?;
    if raw.len() > 4096 {
        return Err("invalid_media_input");
    }
    let url = reqwest::Url::parse(raw).map_err(|_| "invalid_media_input")?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        return Err("invalid_media_input");
    }
    let host = url.host_str().ok_or("invalid_media_input")?;
    let page = match host {
        "youtube.com" | "www.youtube.com" | "m.youtube.com" => {
            let id = if url.path() == "/watch" {
                url.query_pairs()
                    .find(|(k, _)| k == "v")
                    .map(|(_, v)| v.into_owned())
            } else {
                url.path().strip_prefix("/shorts/").map(str::to_owned)
            }
            .ok_or("invalid_media_input")?;
            youtube_page(&id)?
        }
        "youtu.be" => youtube_page(url.path().trim_start_matches('/'))?,
        "bilibili.com" | "www.bilibili.com" | "m.bilibili.com" => {
            let id = url
                .path()
                .trim_end_matches('/')
                .strip_prefix("/video/")
                .ok_or("invalid_media_input")?;
            if id.len() > 64
                || !(id.starts_with("BV") || id.starts_with("av"))
                || !id.bytes().all(|b| b.is_ascii_alphanumeric())
            {
                return Err("invalid_media_input");
            }
            let mut page = format!("https://www.bilibili.com/video/{id}");
            if let Some((_, p)) = url.query_pairs().find(|(k, _)| k == "p") {
                let part: u32 = p.parse().map_err(|_| "invalid_media_input")?;
                if !(1..=1000).contains(&part) {
                    return Err("invalid_media_input");
                }
                page.push_str(&format!("?p={part}"));
            }
            page
        }
        _ => return Err("media_unsupported_site"),
    };
    let height = match v.get("maxHeight") {
        None | Some(Value::Null) => 2160,
        Some(v) => v
            .as_u64()
            .filter(|h| (144..=2160).contains(h))
            .ok_or("invalid_media_input")? as u32,
    };
    let key = format!(
        "{:x}",
        Sha256::digest(format!("public-video-v1|{page}|{height}|avc1|mp4a").as_bytes())
    );
    Ok(Entry { key, page, height })
}
fn youtube_page(id: &str) -> Result<String> {
    if id.len() != 11
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err("invalid_media_input");
    }
    Ok(format!("https://www.youtube.com/watch?v={id}"))
}
fn key(v: &Value) -> Result<String> {
    let k = v["cacheKey"].as_str().ok_or("invalid_media_input")?;
    if k.len() != 64
        || !k
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err("invalid_media_input");
    }
    Ok(k.to_owned())
}
fn list_id(v: &Value) -> Result<String> {
    let id = v["playlistID"]
        .as_str()
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 200
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        })
        .ok_or("invalid_media_input")?;
    Ok(id.to_owned())
}
fn consumer(v: &Value) -> Result<String> {
    match v.get("consumerID") {
        None => Ok("default".into()),
        Some(v) => v
            .as_str()
            .filter(|s| {
                !s.is_empty()
                    && s.len() <= 200
                    && s.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
            })
            .map(str::to_owned)
            .ok_or("invalid_media_input"),
    }
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[derive(Default)]
struct State {
    queue: VecDeque<Entry>,
    known: HashSet<String>,
    protected: HashSet<String>,
    playlist_pins: HashMap<String, HashSet<String>>,
    owners: HashMap<String, HashSet<String>>,
    active: Option<(String, watch::Sender<bool>)>,
    running: bool,
    helpers: Option<Helpers>,
    foreground_burst: usize,
    next_order: u64,
    enqueued: HashMap<String, u64>,
}
impl State {
    fn next(&mut self) -> Option<Entry> {
        let item = if self.foreground_burst >= 4 {
            self.foreground_burst = 0;
            let oldest = self
                .queue
                .iter()
                .enumerate()
                .min_by_key(|(_, entry)| self.enqueued.get(&entry.key).copied().unwrap_or(0))
                .map(|(at, _)| at);
            oldest.and_then(|at| self.queue.remove(at))
        } else {
            self.foreground_burst += 1;
            self.queue.pop_front()
        };
        if let Some(item) = &item {
            self.enqueued.remove(&item.key);
        }
        item
    }
}
pub struct Media {
    db: Database,
    root: PathBuf,
    state: Mutex<State>,
    playlist_lock: Mutex<()>,
    validated: Mutex<HashMap<String, Vec<(PathBuf, u64, SystemTime)>>>,
    entry_locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    playback_sources: Mutex<HashMap<String, Value>>,
    live_resources: Mutex<HashMap<String, Value>>,
    playback_client: Mutex<Option<reqwest::Client>>,
    item_limit: u64,
    cache_limit: u64,
    #[cfg(test)]
    allow_test_sources: bool,
}
impl Media {
    async fn pooled_playback_client(&self) -> Result<reqwest::Client> {
        let mut client = self.playback_client.lock().await;
        if let Some(client) = client.as_ref() {
            return Ok(client.clone());
        }
        let builder = download_client_builder();
        #[cfg(test)]
        let builder = if self.allow_test_sources {
            builder.no_proxy()
        } else {
            builder
        };
        let built = builder.build().map_err(|_| "media_download_failed")?;
        *client = Some(built.clone());
        Ok(built)
    }
    async fn indexed_range(&self, stream: &Value, start: u64, end: u64) -> Result<Vec<u8>> {
        if end < start || end - start >= 16 * 1024 * 1024 {
            return Err("media_invalid_range");
        }
        let length = end - start + 1;
        if let (Some(key), Some(kind)) = (stream["_cacheKey"].as_str(), stream["_kind"].as_str()) {
            let ext = stream["ext"].as_str().unwrap_or("mp4");
            for path in [
                self.root.join(format!("{key}.{kind}.{ext}")),
                self.root.join(format!("{key}.{kind}.part")),
            ] {
                if let Ok(mut file) = tokio::fs::File::open(path).await {
                    if file
                        .metadata()
                        .await
                        .map_err(|_| "storage_unavailable")?
                        .len()
                        > end
                    {
                        file.seek(std::io::SeekFrom::Start(start))
                            .await
                            .map_err(|_| "storage_unavailable")?;
                        let mut bytes = vec![0; length as usize];
                        file.read_exact(&mut bytes)
                            .await
                            .map_err(|_| "storage_unavailable")?;
                        return Ok(bytes);
                    }
                }
            }
        }
        let client = self.pooled_playback_client().await?;
        let url = source_url(stream, self)?;
        let request = source_request(&client, url, stream)?
            .header(reqwest::header::RANGE, format!("bytes={start}-{end}"));
        let mut response = retry_connect_eof(
            || request.try_clone().expect("range request").send(),
            &mut false,
        )
        .await?;
        if !response.status().is_success() {
            return Err(download_http_error(response.status()));
        }
        if response.status() == reqwest::StatusCode::PARTIAL_CONTENT {
            let (first, last, total) = content_range(
                response
                    .headers()
                    .get(reqwest::header::CONTENT_RANGE)
                    .and_then(|v| v.to_str().ok())
                    .ok_or("media_invalid_range")?,
            )?;
            if first != start || last != end.min(total.saturating_sub(1)) {
                return Err("media_invalid_range");
            }
        } else if start != 0 {
            return Err("media_invalid_range");
        }
        // A server may ignore the very first Range. Consume only the requested
        // prefix, then drop the body; never load the complete audio/video here.
        let mut bytes = Vec::with_capacity(length as usize);
        while bytes.len() < length as usize {
            let Some(chunk) = response
                .chunk()
                .await
                .map_err(|_| "media_download_failed")?
            else {
                break;
            };
            let remaining = length as usize - bytes.len();
            bytes.extend_from_slice(&chunk[..remaining.min(chunk.len())]);
        }
        if bytes.is_empty() || (stream.get("_range").is_some() && bytes.len() != length as usize) {
            return Err("media_invalid_range");
        }
        Ok(bytes)
    }
    async fn indexed_playback(
        &self,
        item: &Entry,
        info: &Value,
        video: &Value,
        audio: Option<&Value>,
    ) -> Result<Option<Value>> {
        let mut sources = Vec::new();
        for (kind, source) in [("video", Some(video)), ("audio", audio)] {
            let Some(source) = source else {
                continue;
            };
            let mut stream = json!({"url":source["url"],"ext":source["ext"],"http_headers":source["http_headers"]});
            stream["_cacheKey"] = json!(item.key);
            stream["_kind"] = json!(kind);
            let prefix = self.indexed_range(&stream, 0, 65535).await?;
            let Some(index) = mp4_segment_index(&prefix)? else {
                return Ok(None);
            };
            if index.first_offset > 16 * 1024 * 1024 {
                return Err("media_unsupported_format");
            }
            sources.push((kind, stream, index));
        }
        let cap = uuid::Uuid::new_v4().to_string();
        let mut playlists = HashMap::new();
        let mut resources = self.live_resources.lock().await;
        let resource_count = sources
            .iter()
            .map(|(_, _, index)| index.segments.len() + 2)
            .sum::<usize>()
            + 1;
        if resources.len() + resource_count > 4096 {
            return Err("media_cache_limit");
        }
        let bandwidth = sources
            .iter()
            .map(|(_, _, index)| {
                index
                    .segments
                    .iter()
                    .map(|(_, size, duration)| (*size as f64 * 8.0 / duration).ceil() as u64)
                    .max()
                    .unwrap_or(1)
            })
            .sum::<u64>();
        for (kind, stream, index) in sources {
            let init = uuid::Uuid::new_v4().to_string();
            let mut init_stream = stream.clone();
            init_stream["_range"] = json!([0, index.first_offset - 1]);
            resources.insert(format!("{cap}/{init}"), init_stream);
            let maximum = index
                .segments
                .iter()
                .map(|segment| segment.2.ceil() as u64)
                .max()
                .unwrap_or(1);
            let mut manifest=format!("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:{maximum}\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"/media-live/{cap}/{init}\"\n");
            for (start, size, duration) in index.segments {
                let id = uuid::Uuid::new_v4().to_string();
                let mut segment = stream.clone();
                segment["_range"] = json!([start, start + size - 1]);
                resources.insert(format!("{cap}/{id}"), segment);
                manifest.push_str(&format!("#EXTINF:{duration:.6},\n/media-live/{cap}/{id}\n"));
            }
            manifest.push_str("#EXT-X-ENDLIST\n");
            let id = uuid::Uuid::new_v4().to_string();
            resources.insert(format!("{cap}/{id}"), json!({"_manifest":manifest}));
            playlists.insert(kind, id);
        }
        let video_id = playlists.get("video").ok_or("media_unsupported_format")?;
        let audio_attribute = if let Some(audio_id) = playlists.get("audio") {
            format!("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"/media-live/{cap}/{audio_id}\"\n")
        } else {
            String::new()
        };
        let master=format!("#EXTM3U\n{audio_attribute}#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={}x{}{}\n/media-live/{cap}/{video_id}\n",video["width"].as_u64().unwrap_or(1920),video["height"].as_u64().unwrap_or(1080),if audio.is_some(){",AUDIO=\"audio\""}else{""});
        let id = uuid::Uuid::new_v4().to_string();
        resources.insert(format!("{cap}/{id}"), json!({"_manifest":master}));
        drop(resources);
        let descriptor = json!({"pageURL":item.page,"site":if item.page.contains("bilibili.com"){"bilibili"}else{"youtube"},"title":info["title"].as_str().unwrap_or(""),"durationSeconds":info["duration"],"isLive":false,"audio":null,"video":{"url":format!("/media-live/{cap}/{id}"),"formatID":video["format_id"],"container":"m3u8","videoCodec":video["vcodec"],"audioCodec":audio.unwrap_or(video)["acodec"],"height":video["height"],"width":video["width"],"headers":{},"hasVideo":true,"hasAudio":audio.is_some()||codec(video,"acodec").is_some(),"isManifest":true}});
        Ok(Some(json!({"descriptor":descriptor,"capability":cap})))
    }
    async fn prepare_live(&self, item: &Entry, info: &Value) -> Result<(Value, u64)> {
        if info["has_drm"] == true
            || info["age_limit"].as_u64().is_some_and(|age| age > 0)
            || info["availability"]
                .as_str()
                .is_some_and(|a| !["public", "unlisted"].contains(&a))
        {
            return Err("media_restricted");
        }
        let formats = info["formats"]
            .as_array()
            .cloned()
            .unwrap_or_else(|| vec![info.clone()]);
        let mut candidates: Vec<_> = formats
            .into_iter()
            .filter(|v| {
                matches!(v["protocol"].as_str(), Some("m3u8" | "m3u8_native"))
                    && codec(v, "vcodec").is_some_and(|c| c.starts_with("avc1") || c == "h264")
                    && codec(v, "acodec").is_some_and(|c| c.starts_with("mp4a") || c == "aac")
                    && v["height"]
                        .as_u64()
                        .is_some_and(|h| h <= item.height as u64)
                    && v["has_drm"] != true
            })
            .collect();
        candidates.sort_by_key(|v| v["height"].as_u64().unwrap_or(0));
        let mut stream = candidates.pop().ok_or("media_unsupported_format")?;
        if stream.get("http_headers").is_none() {
            stream["http_headers"] = info["http_headers"].clone();
        }
        source_url(&stream, self)?;
        let cap = uuid::Uuid::new_v4().to_string();
        let id = uuid::Uuid::new_v4().to_string();
        self.live_resources
            .lock()
            .await
            .insert(format!("{cap}/{id}"), stream.clone());
        let descriptor = json!({"pageURL":item.page,"site":if item.page.contains("bilibili.com") {"bilibili"} else {"youtube"},"title":info["title"].as_str().unwrap_or(""),"isLive":true,"durationSeconds":null,"audio":null,
            "video":{"url":format!("/media-live/{cap}/{id}"),"formatID":stream["format_id"],"container":"m3u8","videoCodec":stream["vcodec"],"audioCodec":stream["acodec"],"height":stream["height"],"width":stream["width"],"headers":{},"hasVideo":true,"hasAudio":true,"isManifest":true}});
        self.playback_sources.lock().await.insert(
            item.key.clone(),
            json!({"descriptor":descriptor,"capability":cap}),
        );
        self.set_state(&item.key, "streaming", None).await?;
        Ok((descriptor, 0))
    }
    pub(crate) async fn live_resource(
        &self,
        capability: &str,
        resource: &str,
    ) -> Result<(String, Vec<u8>)> {
        if uuid::Uuid::parse_str(capability).is_err() || uuid::Uuid::parse_str(resource).is_err() {
            return Err("invalid_media_input");
        }
        let stream = self
            .live_resources
            .lock()
            .await
            .get(&format!("{capability}/{resource}"))
            .cloned()
            .ok_or("media_cache_missing")?;
        if let Some(manifest) = stream["_manifest"].as_str() {
            return Ok((
                "application/vnd.apple.mpegurl".into(),
                manifest.as_bytes().to_vec(),
            ));
        }
        if let (Some(start), Some(end)) =
            (stream["_range"][0].as_u64(), stream["_range"][1].as_u64())
        {
            return Ok((
                "video/mp4".into(),
                self.indexed_range(&stream, start, end).await?,
            ));
        }
        let url = source_url(&stream, self)?;
        let mut builder = download_client_builder();
        #[cfg(test)]
        if self.allow_test_sources {
            builder = builder.no_proxy();
        }
        let client = builder.build().map_err(|_| "media_download_failed")?;
        let mut response = source_request(&client, url.clone(), &stream)?
            .send()
            .await
            .map_err(|_| "media_download_failed")?;
        // The client has a 60s deadline covering headers and every body chunk;
        // live means repeated bounded segment requests, never an endless body.
        if !response.status().is_success() {
            return Err(download_http_error(response.status()));
        }
        let mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_owned();
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "media_download_failed")?
        {
            if bytes.len() + chunk.len() > 32 * 1024 * 1024 {
                return Err("media_cache_limit");
            }
            bytes.extend_from_slice(&chunk);
        }
        if !bytes.starts_with(b"#EXTM3U") {
            return Ok((mime, bytes));
        }
        let text = std::str::from_utf8(&bytes).map_err(|_| "media_unsupported_format")?;
        let mut rewritten = String::new();
        for line in text.lines() {
            let mut line = line.to_owned();
            if !line.is_empty() && !line.starts_with('#') {
                line = self
                    .register_live_uri(capability, &url, &line, &stream)
                    .await?;
            } else if let Some(at) = line.find("URI=\"") {
                let start = at + 5;
                let end = line[start..]
                    .find('"')
                    .map(|n| start + n)
                    .ok_or("media_unsupported_format")?;
                let replacement = self
                    .register_live_uri(capability, &url, &line[start..end], &stream)
                    .await?;
                line.replace_range(start..end, &replacement);
            }
            rewritten.push_str(&line);
            rewritten.push('\n');
        }
        Ok((
            "application/vnd.apple.mpegurl".into(),
            rewritten.into_bytes(),
        ))
    }
    async fn register_live_uri(
        &self,
        cap: &str,
        base: &reqwest::Url,
        uri: &str,
        parent: &Value,
    ) -> Result<String> {
        let url = base.join(uri).map_err(|_| "media_unsupported_format")?;
        // Child resources need only the resolved URL and request headers;
        // never duplicate an extractor's potentially large fragments metadata.
        let mut stream = json!({"url":url.as_str(),"http_headers":parent["http_headers"]});
        source_url(&stream, self)?;
        let id = format!("{:x}", Sha256::digest(url.as_str().as_bytes()));
        // A deterministic UUID keeps a sliding playlist from growing duplicate resources.
        let id = uuid::Uuid::parse_str(&format!(
            "{}-{}-{}-{}-{}",
            &id[0..8],
            &id[8..12],
            &id[12..16],
            &id[16..20],
            &id[20..32]
        ))
        .map_err(|_| "worker_failed")?
        .to_string();
        stream["_registeredAt"] = json!(now());
        let mut resources = self.live_resources.lock().await;
        resources.retain(|key, value| {
            !key.starts_with(&format!("{cap}/"))
                || value["_registeredAt"]
                    .as_i64()
                    .is_none_or(|time| now() - time < 600)
        });
        if resources.len() >= 4096 {
            return Err("media_cache_limit");
        }
        resources.insert(format!("{cap}/{id}"), stream);
        Ok(format!("/media-live/{cap}/{id}"))
    }
    /// An authenticated loopback request reads only an extractor-selected track.
    /// Source URLs remain in memory and errors never contain their signatures.
    pub(crate) async fn playback_range(
        &self,
        cache_key: &str,
        kind: &str,
        range: &str,
    ) -> Result<reqwest::Response> {
        key(&json!({"cacheKey":cache_key}))?;
        if !matches!(kind, "video" | "audio") || !valid_playback_range(range) {
            return Err("invalid_media_input");
        }
        #[cfg(debug_assertions)]
        if std::env::var_os("GMGN_MEDIA_RANGE_TRACE").is_some() {
            eprintln!("MEDIA_PLAYBACK_RANGE request kind={kind} range={range}");
        }
        let stream = self
            .playback_sources
            .lock()
            .await
            .get(cache_key)
            .and_then(|source| source.get(kind))
            .filter(|source| !source.is_null())
            .cloned()
            .ok_or("media_cache_missing")?;
        let url = source_url(&stream, self)?;
        let mut builder = download_client_builder();
        #[cfg(test)]
        if self.allow_test_sources {
            builder = builder.no_proxy();
        }
        let client = builder.build().map_err(|_| "media_download_failed")?;
        let request = source_request(&client, url, &stream)?.header(reqwest::header::RANGE, range);
        let response = retry_connect_eof(
            || request.try_clone().expect("bodyless range").send(),
            &mut false,
        )
        .await?;
        #[cfg(debug_assertions)]
        if std::env::var_os("GMGN_MEDIA_RANGE_TRACE").is_some() {
            eprintln!(
                "MEDIA_PLAYBACK_RANGE response kind={kind} status={} length={}",
                response.status().as_u16(),
                response.content_length().unwrap_or(0)
            );
        }
        if !response.status().is_success() {
            return Err(download_http_error(response.status()));
        }
        if response.status() != reqwest::StatusCode::PARTIAL_CONTENT {
            return Err("media_invalid_range");
        }
        let (start, end, total) = content_range(
            response
                .headers()
                .get(reqwest::header::CONTENT_RANGE)
                .and_then(|value| value.to_str().ok())
                .ok_or("media_invalid_range")?,
        )?;
        #[cfg(debug_assertions)]
        if std::env::var_os("GMGN_MEDIA_RANGE_TRACE").is_some() {
            eprintln!("MEDIA_PLAYBACK_RANGE content_range kind={kind} start={start} end={end} total={total}");
        }
        let (requested_start, requested_end) = range
            .trim_start_matches("bytes=")
            .split_once('-')
            .ok_or("media_invalid_range")?;
        let requested_start: u64 = requested_start.parse().map_err(|_| "media_invalid_range")?;
        let requested_end: u64 = requested_end.parse().map_err(|_| "media_invalid_range")?;
        if total == 0
            || start != requested_start
            || end != requested_end.min(total - 1)
            || end < start
        {
            return Err("media_invalid_range");
        }
        Ok(response)
    }
    pub fn new(db: Database) -> Arc<Self> {
        Arc::new(Self {
            root: db.root.join("media-cache"),
            db,
            state: Mutex::new(State::default()),
            playlist_lock: Mutex::new(()),
            validated: Mutex::new(HashMap::new()),
            entry_locks: Mutex::new(HashMap::new()),
            playback_sources: Mutex::new(HashMap::new()),
            live_resources: Mutex::new(HashMap::new()),
            playback_client: Mutex::new(None),
            item_limit: ITEM_LIMIT,
            cache_limit: CACHE_LIMIT,
            #[cfg(test)]
            allow_test_sources: false,
        })
    }
    pub async fn initialize(self: &Arc<Self>, helpers: Option<Helpers>) -> Result<()> {
        if let Some(h) = &helpers {
            verify_helper(&h.helper, &h.helper_sha256)?;
            verify_helper(&h.deno, &h.deno_sha256)?;
        }
        files::directory(&self.root)?;
        self.state.lock().await.helpers = helpers;
        self.db.call(|s| {
            let code = "media_interrupted";
            s.connection.execute("UPDATE media_cache SET state='interrupted',error=?1,bytes=0 WHERE state IN ('queued','resolving','downloading','streaming')",[code]).map_err(|_| "storage_unavailable")?;
            Ok(())
        }).await?;
        let ready_keys = self
            .db
            .call(|s| {
                let mut statement = s
                    .connection
                    .prepare("SELECT cache_key FROM media_cache WHERE state='ready'")
                    .map_err(|_| "storage_unavailable")?;
                let rows = statement
                    .query_map([], |r| r.get::<_, String>(0))
                    .map_err(|_| "storage_unavailable")?;
                rows.collect::<std::result::Result<HashSet<_>, _>>()
                    .map_err(|_| "storage_unavailable")
            })
            .await?;
        // Only cache-owned transient files are cleaned; completed files survive.
        for file in std::fs::read_dir(&self.root).map_err(|_| "storage_unavailable")? {
            let path = file.map_err(|_| "storage_unavailable")?.path();
            let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
            let owned = name.split_once('.').filter(|(k, suffix)| {
                k.len() == 64
                    && k.bytes().all(|b| b.is_ascii_hexdigit())
                    && [
                        "video.part",
                        "audio.part",
                        "video.mp4",
                        "audio.mp4",
                        "audio.m4a",
                    ]
                    .contains(suffix)
            });
            if owned.is_some_and(|(k, _)| {
                path.extension().is_some_and(|e| e == "part") || !ready_keys.contains(k)
            }) && std::fs::symlink_metadata(&path)
                .is_ok_and(|m| m.is_file() && !m.file_type().is_symlink())
            {
                std::fs::remove_file(path).map_err(|_| "storage_unavailable")?;
            }
        }
        let lists = self
            .db
            .call(|s| {
                let mut stmt = s
                    .connection
                    .prepare("SELECT id,payload,current_index FROM video_playlists")
                    .map_err(|_| "storage_unavailable")?;
                let rows = stmt
                    .query_map([], |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, String>(1)?,
                            r.get::<_, usize>(2)?,
                        ))
                    })
                    .map_err(|_| "storage_unavailable")?;
                rows.collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(|_| "storage_unavailable")
            })
            .await?;
        {
            let mut state = self.state.lock().await;
            for (id, payload, index) in &lists {
                let items: Value =
                    serde_json::from_str(payload).map_err(|_| "media_storage_corrupt")?;
                let mut pins = HashSet::new();
                for at in [*index, *index + 1] {
                    if let Some(v) = items.get(at) {
                        pins.insert(entry(v)?.key);
                    }
                }
                state.playlist_pins.insert(id.clone(), pins);
            }
            state.protected = state
                .playlist_pins
                .values()
                .flat_map(|v| v.iter().cloned())
                .collect();
        }
        for (id, payload, index) in lists {
            let items: Value =
                serde_json::from_str(&payload).map_err(|_| "media_storage_corrupt")?;
            self.prefetch(&id, &items, index).await?;
        }
        Ok(())
    }
    pub async fn request(self: &Arc<Self>, method: &str, input: Value) -> Result<Value> {
        match method {
            "media_prepare" => {
                let item = entry(&input)?;
                let pin = input["pin"].as_bool().unwrap_or(true);
                let owner = consumer(&input)?;
                let added = if pin {
                    self.state
                        .lock()
                        .await
                        .owners
                        .entry(item.key.clone())
                        .or_default()
                        .insert(owner.clone())
                } else {
                    false
                };
                let result = self.prepare(item.clone(), pin).await;
                if result.is_err() && added {
                    if let Some(owners) = self.state.lock().await.owners.get_mut(&item.key) {
                        owners.remove(&owner);
                    }
                }
                result
            }
            "media_status" => self.status(&key(&input)?).await,
            "media_release" => {
                let cache_key = key(&input)?;
                let mut state = self.state.lock().await;
                if let Some(owners) = state.owners.get_mut(&cache_key) {
                    owners.remove(&consumer(&input)?);
                }
                drop(state);
                self.release_playback_if_unheld(&cache_key).await?;
                Ok(json!({"released":true}))
            }
            "media_cancel" => self.cancel(&key(&input)?).await,
            "media_playlist_read" => self.playlist_read(&list_id(&input)?).await,
            "media_playlist_import" => self.playlist_import(input).await,
            "media_playlist_release" => {
                let _guard = self.playlist_lock.lock().await;
                let id = list_id(&input)?;
                // Screen queues are per-session, not user-saved lists. A stopped
                // screen must not restart speculative downloads on daemon restart.
                if id.strip_prefix("screen-").is_some_and(|suffix| uuid::Uuid::parse_str(suffix).is_ok()) {
                    let saved_id=id.clone();
                    self.db.call(move |s| {
                        s.connection.execute("DELETE FROM video_playlists WHERE id=?1",[saved_id]).map_err(|_|"storage_unavailable")?;
                        Ok(())
                    }).await?;
                }
                let mut state = self.state.lock().await;
                let released = state.playlist_pins.remove(&id).unwrap_or_default();
                state.protected = state.playlist_pins.values().flat_map(|set| set.iter().cloned()).collect();
                drop(state);
                for key in released {
                    self.cancel(&key).await?;
                    self.release_playback_if_unheld(&key).await?;
                }
                Ok(json!({"released":true}))
            }
            "media_playlist_commit" | "media_playlist_advance" => {
                self.playlist_change(method, input).await
            }
            _ => Err("unknown_method"),
        }
    }
    async fn release_playback_if_unheld(&self, cache_key:&str) -> Result<()> {
        // A screen may have imported its queue without yet registering a native
        // playback owner. Both forms of ownership protect the same capability.
        // Hold the scheduler lock through revocation so concurrent prepare cannot
        // register its owner between the last-holder check and removal.
        let state=self.state.lock().await;
        if state.protected.contains(cache_key) || state.owners.get(cache_key).is_some_and(|owners|!owners.is_empty()) {
            return Ok(());
        }
        let source=self.playback_sources.lock().await.remove(cache_key);
        if let Some(capability)=source.as_ref().and_then(|source|source["capability"].as_str()) {
            self.live_resources.lock().await.retain(|key,_|!key.starts_with(&format!("{capability}/")));
            if source.as_ref().is_some_and(|source|source["descriptor"]["isLive"] == true) {
                self.set_state(cache_key,"cancelled",None).await?;
            }
        }
        drop(state);
        Ok(())
    }
    async fn status(&self, cache_key: &str) -> Result<Value> {
        let _entry_guard = self.entry_lock(cache_key).await.lock_owned().await;
        let k = cache_key.to_owned();
        let row = self
            .db
            .call(move |s| {
                s.connection
                    .query_row(
                        "SELECT state,payload,error FROM media_cache WHERE cache_key=?1",
                        [&k],
                        |r| {
                            Ok((
                                r.get::<_, String>(0)?,
                                r.get::<_, String>(1)?,
                                r.get::<_, Option<String>>(2)?,
                            ))
                        },
                    )
                    .optional()
                    .map_err(|_| "storage_unavailable")
            })
            .await?;
        let Some((state, payload, error)) = row else {
            return Ok(json!({"cacheKey":cache_key,"state":"missing"}));
        };
        let descriptor: Value =
            serde_json::from_str(&payload).map_err(|_| "media_storage_corrupt")?;
        if state == "ready" && !descriptor_files_valid(&self.root, &descriptor, false)? {
            self.cleanup_finished(cache_key);
            self.set_state(cache_key, "interrupted", Some("media_cache_missing"))
                .await?;
            return Ok(
                json!({"cacheKey":cache_key,"state":"interrupted","error":"media_cache_missing"}),
            );
        }
        if state == "ready" {
            let fingerprint = fingerprint(&self.root, &descriptor)?;
            if self.validated.lock().await.get(cache_key) != Some(&fingerprint) {
                let root = self.root.clone();
                let document = descriptor.clone();
                let valid = tokio::task::spawn_blocking(move || {
                    descriptor_files_valid(&root, &document, true)
                })
                .await
                .map_err(|_| "worker_failed")??;
                if !valid {
                    self.cleanup_finished(cache_key);
                    self.set_state(cache_key, "interrupted", Some("media_cache_corrupt"))
                        .await?;
                    return Ok(
                        json!({"cacheKey":cache_key,"state":"interrupted","error":"media_cache_corrupt"}),
                    );
                }
                self.validated
                    .lock()
                    .await
                    .insert(cache_key.into(), fingerprint);
            }
        }
        let mut result = json!({"cacheKey":cache_key,"state":state});
        if state == "ready" {
            result["descriptor"] = descriptor;
        } else if state == "downloading" || state == "streaming" {
            if let Some(playback) = self.playback_sources.lock().await.get(cache_key) {
                result["streamingDescriptor"] = playback["descriptor"].clone();
            }
        }
        if let Some(error) = error {
            result["error"] = json!(error);
        }
        Ok(result)
    }
    async fn prepare(self: &Arc<Self>, item: Entry, pin: bool) -> Result<Value> {
        let existing = self.status(&item.key).await?;
        if existing["state"] == "streaming" {
            return Ok(existing);
        }
        if existing["state"] == "ready" {
            let k = item.key.clone();
            self.db
                .call(move |s| {
                    s.connection
                        .execute(
                            "UPDATE media_cache SET last_used=?2 WHERE cache_key=?1",
                            params![k, now()],
                        )
                        .map_err(|_| "storage_unavailable")?;
                    Ok(())
                })
                .await?;
            return Ok(existing);
        }
        let mut state = self.state.lock().await;
        // A download may have finished while this request waited for the
        // scheduler lock. Re-read after the atomic ready/in-flight handoff.
        let current = self.status(&item.key).await?;
        if current["state"] == "ready" {
            return Ok(current);
        }
        if state.known.contains(&item.key) {
            if pin {
                if let Some(at) = state.queue.iter().position(|e| e.key == item.key) {
                    let e = state.queue.remove(at).unwrap();
                    state.queue.push_front(e);
                }
            }
            drop(state);
            return self.status(&item.key).await;
        }
        if state.helpers.is_none() {
            return Err("media_helper_unavailable");
        }
        if state.known.len() >= 64 {
            return Err("media_queue_full");
        }
        files::directory(&self.root)?;
        let row = item.clone();
        self.db.call(move |s| {
            s.connection.execute("INSERT INTO media_cache(cache_key,page_url,height,state,payload,last_used) VALUES(?1,?2,?3,'queued','{}',?4) ON CONFLICT(cache_key) DO UPDATE SET state='queued',error=NULL,last_used=excluded.last_used",params![row.key,row.page,row.height,now()]).map_err(|_| "storage_unavailable")?;
            Ok(())
        }).await?;
        state.known.insert(item.key.clone());
        let order = state.next_order;
        state.next_order = state.next_order.saturating_add(1);
        state.enqueued.insert(item.key.clone(), order);
        if pin {
            state.queue.push_front(item.clone());
        } else {
            state.queue.push_back(item.clone());
        }
        if !state.running {
            state.running = true;
            let media = self.clone();
            tokio::spawn(async move {
                media.worker().await;
            });
        }
        drop(state);
        self.status(&item.key).await
    }
    async fn set_state(&self, k: &str, state: &str, error: Option<&str>) -> Result<()> {
        let (k, state, error) = (k.to_owned(), state.to_owned(), error.map(str::to_owned));
        self.db
            .call(move |s| {
                s.connection
                    .execute(
                        "UPDATE media_cache SET state=?2,error=?3,bytes=CASE WHEN ?2 IN ('resolving','interrupted','evicted','failed','cancelled') THEN 0 ELSE bytes END WHERE cache_key=?1",
                        params![k, state, error],
                    )
                    .map_err(|_| "storage_unavailable")?;
                let sequence = s.changed.borrow().wrapping_add(1);
                s.changed.send_replace(sequence);
                Ok(())
            })
            .await
    }
    async fn entry_lock(&self, key: &str) -> Arc<Mutex<()>> {
        self.entry_locks
            .lock()
            .await
            .entry(key.into())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }
    async fn cancel(&self, k: &str) -> Result<Value> {
        let mut state = self.state.lock().await;
        if state.protected.contains(k) || state.owners.get(k).is_some_and(|v| !v.is_empty()) {
            drop(state);
            return self.status(k).await;
        }
        let queued_cancel = state.queue.iter().any(|e| e.key == k);
        state.queue.retain(|e| e.key != k);
        let active_cancel = state.active.as_ref().is_some_and(|(active, _)| active == k);
        if !active_cancel {
            state.known.remove(k);
            state.enqueued.remove(k);
        }
        if let Some((active, tx)) = &state.active {
            if active == k {
                tx.send_replace(true);
            }
        }
        // Only cancel work actually owned by the scheduler. Keep completed
        // failure diagnostics intact when a consumer releases its session.
        // Publish queued cancellation under the scheduler lock so a new
        // prepare cannot race this update.
        if queued_cancel && !active_cancel {
            self.set_state(k, "cancelled", None).await?;
        }
        drop(state);
        self.status(k).await
    }
    async fn worker(self: Arc<Self>) {
        loop {
            let (item, helpers, mut cancel) = {
                let mut s = self.state.lock().await;
                let item = s.next();
                let Some(item) = item else {
                    s.running = false;
                    return;
                };
                let Some(helpers) = s.helpers.clone() else {
                    s.running = false;
                    return;
                };
                let (tx, rx) = watch::channel(false);
                s.active = Some((item.key.clone(), tx));
                (item, helpers, rx)
            };
            let result = tokio::select! {
                value=tokio::time::timeout(Duration::from_secs(600),self.download(&item,&helpers)) => value.unwrap_or(Err("media_download_timeout")),
                _=cancel.changed() => Err("media_cancelled"),
            };
            // Same state -> entry lock order as eviction. Cleanup and removal
            // from the in-flight set precede the terminal state publication.
            let mut s = self.state.lock().await;
            let cancelled = *cancel.borrow();
            let _entry_guard = self.entry_lock(&item.key).await.lock_owned().await;
            self.cleanup_parts(&item.key);
            if result.is_err() || cancelled {
                self.cleanup_finished(&item.key);
                self.playback_sources.lock().await.remove(&item.key);
            }
            s.active = None;
            s.known.remove(&item.key);
            if cancelled || result == Err("media_cancelled") {
                let _ = self.set_state(&item.key, "cancelled", None).await;
            } else {
                match result {
                    Err(code) => {
                        let _ = self.set_state(&item.key, "failed", Some(code)).await;
                    }
                    Ok((descriptor, total)) => {
                        if descriptor["isLive"] == true {
                            continue;
                        }
                        let key = item.key.clone();
                        let payload = descriptor.to_string();
                        if self.db.call(move |store| {
                            store.connection.execute("UPDATE media_cache SET state='ready',payload=?2,bytes=?3,last_used=?4,error=NULL WHERE cache_key=?1",params![key,payload,total as i64,now()]).map_err(|_|"storage_unavailable")?;
                            let sequence=store.changed.borrow().wrapping_add(1);store.changed.send_replace(sequence);Ok(())
                        }).await.is_err() {
                            self.cleanup_finished(&item.key);
                            let _=self.set_state(&item.key,"failed",Some("storage_unavailable")).await;
                        }
                    }
                }
            }
        }
    }
    fn cleanup_parts(&self, key: &str) {
        for kind in ["video", "audio"] {
            let path = self.root.join(format!("{key}.{kind}.part"));
            let _ = std::fs::remove_file(path);
        }
    }
    fn cleanup_finished(&self, key: &str) {
        for suffix in ["video.mp4", "audio.mp4", "audio.m4a"] {
            let _ = std::fs::remove_file(self.root.join(format!("{key}.{suffix}")));
        }
    }
    async fn playlist_import(self: &Arc<Self>, input: Value) -> Result<Value> {
        let (page, video, requested_index, limit) = youtube_playlist_input(&input)?;
        let helpers = self.state.lock().await.helpers.clone().ok_or("media_helper_unavailable")?;
        let metadata = resolve_playlist(&page, limit, &helpers).await?;
        let (items, index, truncated) = playlist_items(&metadata, video.as_deref(), requested_index, limit)?;
        let mut commit = input;
        commit["items"] = items;
        commit["currentIndex"] = json!(index);
        let mut result = self.playlist_change("media_playlist_commit", commit).await?;
        result["truncated"] = json!(truncated);
        result["itemLimit"] = json!(limit);
        result["title"] = metadata["title"].clone();
        Ok(result)
    }
    async fn playlist_read(&self, id: &str) -> Result<Value> {
        let id_owned = id.to_owned();
        let row = self
            .db
            .call(move |s| {
                s.connection
                    .query_row(
                        "SELECT revision,current_index,payload FROM video_playlists WHERE id=?1",
                        [id_owned],
                        |r| {
                            Ok((
                                r.get::<_, i64>(0)?,
                                r.get::<_, usize>(1)?,
                                r.get::<_, String>(2)?,
                            ))
                        },
                    )
                    .optional()
                    .map_err(|_| "storage_unavailable")
            })
            .await?;
        let Some((revision, index, payload)) = row else {
            return Ok(json!({"playlistID":id,"revision":0,"currentIndex":0,"items":[]}));
        };
        let items: Value = serde_json::from_str(&payload).map_err(|_| "media_storage_corrupt")?;
        let mut result =
            json!({"playlistID":id,"revision":revision,"currentIndex":index,"items":items});
        for (name, at) in [("current", index), ("next", index + 1)] {
            if let Some(item) = items.get(at) {
                result[name] = self.status(&entry(item)?.key).await?;
            }
        }
        Ok(result)
    }
    async fn playlist_change(self: &Arc<Self>, method: &str, input: Value) -> Result<Value> {
        let _playlist_guard = self.playlist_lock.lock().await;
        let id = list_id(&input)?;
        let previous = self.playlist_read(&id).await?;
        let base = input["baseRevision"]
            .as_i64()
            .filter(|n| *n >= 0)
            .ok_or("invalid_media_revision")?;
        let items = if method == "media_playlist_commit" {
            let rows = input["items"]
                .as_array()
                .filter(|v| v.len() <= MAX_LIST_ITEMS)
                .ok_or("invalid_media_input")?;
            let mut items = Vec::new();
            for row in rows {
                let item = entry(row)?;
                items
                    .push(json!({"pageURL":item.page,"maxHeight":item.height,"cacheKey":item.key}));
            }
            json!(items)
        } else {
            previous["items"].clone()
        };
        let length = items.as_array().ok_or("media_storage_corrupt")?.len();
        let index = if method == "media_playlist_commit" {
            input["currentIndex"].as_u64().unwrap_or(0) as usize
        } else {
            input["index"]
                .as_u64()
                .map(|n| n as usize)
                .unwrap_or(previous["currentIndex"].as_u64().unwrap_or(0) as usize + 1)
        };
        if (length == 0 && index != 0) || (length > 0 && index >= length) {
            return Err("invalid_media_input");
        }
        let id_save = id.clone();
        let payload = items.to_string();
        self.db.call(move |s| {
            let tx=s.connection.transaction().map_err(|_|"storage_unavailable")?;
            let revision=tx.query_row("SELECT revision FROM video_playlists WHERE id=?1",[&id_save],|r|r.get::<_,i64>(0)).optional().map_err(|_|"storage_unavailable")?.unwrap_or(0);
            if revision!=base {return Err("media_revision_conflict");}
            let next=revision.checked_add(1).ok_or("invalid_media_revision")?;
            tx.execute("INSERT INTO video_playlists VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,current_index=excluded.current_index,payload=excluded.payload",params![id_save,next,index as i64,payload]).map_err(|_|"storage_unavailable")?;
            tx.commit().map_err(|_|"storage_unavailable")?;Ok(())
        }).await?;
        let prepared = self.prefetch(&id, &items, index).await;
        let mut response = self.playlist_read(&id).await?;
        if let Err(code) = prepared {
            response["prefetchError"] = json!(code);
        }
        Ok(response)
    }
    async fn prefetch(self: &Arc<Self>, id: &str, items: &Value, index: usize) -> Result<()> {
        let mut pins = HashSet::new();
        for at in [index, index + 1] {
            if let Some(v) = items.get(at) {
                pins.insert(entry(v)?.key);
            }
        }
        {
            let mut state = self.state.lock().await;
            state.playlist_pins.insert(id.into(), pins);
            state.protected = state
                .playlist_pins
                .values()
                .flat_map(|set| set.iter().cloned())
                .collect();
        }
        // Current goes first; next is the only speculative item.
        for at in [index, index + 1] {
            if let Some(v) = items.get(at) {
                let item = entry(v)?;
                match self.prepare(item, at == index).await {
                    Ok(_) => {}
                    Err("media_helper_unavailable") => {}
                    Err(code) => return Err(code),
                }
            }
        }
        Ok(())
    }
    async fn download(&self, item: &Entry, helpers: &Helpers) -> Result<(Value, u64)> {
        for generation in 0..2 {
            let mut exhausted_eof = false;
            let result = self
                .download_attempt(item, helpers, &mut exhausted_eof)
                .await;
            if generation == 0 && exhausted_eof {
                // A fresh extraction may select a reachable public CDN. Never
                // mix tracks or partial bytes from different source generations.
                let _guard = self.entry_lock(&item.key).await.lock_owned().await;
                self.cleanup_parts(&item.key);
                self.cleanup_finished(&item.key);
                eprintln!("media download source refresh after exhausted TLS EOF: generation=2");
                continue;
            }
            return result;
        }
        unreachable!()
    }
    async fn download_attempt(
        &self,
        item: &Entry,
        helpers: &Helpers,
        exhausted_eof: &mut bool,
    ) -> Result<(Value, u64)> {
        // An interrupted/corrupt generation is never playable. Do not retain
        // its old final bytes while writing a fresh .part for the same key.
        {
            let _entry_guard = self.entry_lock(&item.key).await.lock_owned().await;
            self.cleanup_finished(&item.key);
            self.set_state(&item.key, "resolving", None).await?;
        }
        let info = resolve(item, helpers).await?;
        if info["is_live"] == true || info["live_status"] == "is_live" {
            return self.prepare_live(item, &info).await;
        }
        let (video, audio) = streams(&info, item.height)?;
        let playback = if let Some(indexed) = self
            .indexed_playback(item, &info, &video, audio.as_ref())
            .await?
        {
            indexed
        } else {
            let descriptor = playback_descriptor(item, &info, &video, audio.as_ref(), self)?;
            json!({"descriptor":descriptor,"video":video,"audio":audio})
        };
        self.playback_sources
            .lock()
            .await
            .insert(item.key.clone(), playback);
        self.set_state(&item.key, "downloading", None).await?;
        // Honor the user's configured network route. CDN redirects remain
        // bounded and subject to the same public-source policy as extraction.
        let builder = download_client_builder();
        #[cfg(test)]
        let builder = if self.allow_test_sources {
            builder.no_proxy()
        } else {
            builder
        };
        let client = builder.build().map_err(|_| "media_download_failed")?;
        let mut total = 0;
        let mut descriptor = json!({"pageURL":item.page,"site":if item.page.contains("bilibili.com") {"bilibili"} else {"youtube"},
            "title":info["title"].as_str().unwrap_or(""),"durationSeconds":info["duration"],"isLive":false,"audio":null});
        for (kind, stream) in [("video", Some(video)), ("audio", audio)] {
            let Some(stream) = stream else {
                continue;
            };
            let url = source_url(&stream, self)?;
            let part = self.root.join(format!("{}.{kind}.part", item.key));
            let (bytes, hash) = self
                .fetch(
                    &client,
                    &url,
                    &stream,
                    &part,
                    self.item_limit - total,
                    &item.key,
                    total,
                    exhausted_eof,
                )
                .await?;
            total = total.checked_add(bytes).ok_or("media_cache_limit")?;
            let ext = stream["ext"]
                .as_str()
                .filter(|s| matches!(*s, "mp4" | "m4a"))
                .ok_or("media_unsupported_format")?;
            let final_path = self.root.join(format!("{}.{kind}.{ext}", item.key));
            let file_url = reqwest::Url::from_file_path(&final_path).map_err(|_| "unsafe_path")?;
            descriptor[kind] = json!({"url":file_url.as_str(),"formatID":stream["format_id"].as_str().unwrap_or(""),
                "container":ext,"videoCodec":codec(&stream,"vcodec"),"audioCodec":codec(&stream,"acodec"),
                "width":stream["width"],"height":stream["height"],"frameRate":stream["fps"],
                "isManifest":false,"hasVideo":kind=="video","hasAudio":codec(&stream,"acodec").is_some(),
                "headers":{},"bytes":bytes,"sha256":hash});
        }
        self.evict(total, &item.key).await?;
        let _entry_guard = self.entry_lock(&item.key).await.lock_owned().await;
        // The two tracks become visible only after both downloads are complete.
        for kind in ["video", "audio"] {
            if let Some(track) = descriptor.get(kind).filter(|v| !v.is_null()) {
                let final_path = reqwest::Url::parse(track["url"].as_str().unwrap())
                    .map_err(|_| "unsafe_path")?
                    .to_file_path()
                    .map_err(|_| "unsafe_path")?;
                tokio::fs::rename(
                    self.root.join(format!("{}.{kind}.part", item.key)),
                    final_path,
                )
                .await
                .map_err(|_| "storage_unavailable")?;
            }
        }
        Ok((descriptor, total))
    }
    async fn evict(&self, incoming: u64, current: &str) -> Result<()> {
        let _playlist_guard = self.playlist_lock.lock().await;
        let state = self.state.lock().await;
        let mut protected = state.protected.clone();
        protected.extend(
            state
                .owners
                .iter()
                .filter(|(_, v)| !v.is_empty())
                .map(|(k, _)| k.clone()),
        );
        protected.extend(state.known.iter().cloned());
        protected.insert(current.into());
        let rows=self.db.call(|s| {
                let mut statement=s.connection.prepare("SELECT cache_key,bytes,payload FROM media_cache WHERE bytes>0 ORDER BY last_used,cache_key").map_err(|_|"storage_unavailable")?;
            let rows=statement.query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,u64>(1)?,r.get::<_,String>(2)?))).map_err(|_|"storage_unavailable")?;
            rows.collect::<std::result::Result<Vec<_>,_>>().map_err(|_|"storage_unavailable")
        }).await?;
        let mut used = rows
            .iter()
            .try_fold(incoming, |acc, (k, n, _)| {
                if k == current {
                    Some(acc)
                } else {
                    acc.checked_add(*n)
                }
            })
            .ok_or("media_cache_limit")?;
        for (key, bytes, payload) in rows {
            if used <= self.cache_limit {
                break;
            }
            if protected.contains(&key) {
                continue;
            }
            let _entry_guard = self.entry_lock(&key).await.lock_owned().await;
            let descriptor: Value =
                serde_json::from_str(&payload).map_err(|_| "media_storage_corrupt")?;
            // Only known files in the private cache directory may be deleted.
            for kind in ["video", "audio"] {
                if let Some(track) = descriptor.get(kind).filter(|v| !v.is_null()) {
                    let url =
                        reqwest::Url::parse(track["url"].as_str().ok_or("media_storage_corrupt")?)
                            .map_err(|_| "media_storage_corrupt")?;
                    let path = url.to_file_path().map_err(|_| "media_storage_corrupt")?;
                    if path.parent() != Some(&self.root) {
                        return Err("unsafe_path");
                    }
                    match std::fs::remove_file(path) {
                        Ok(_) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                        Err(_) => return Err("storage_unavailable"),
                    }
                }
            }
            self.set_state(&key, "evicted", None).await?;
            used -= bytes;
        }
        if used > self.cache_limit {
            return Err("media_cache_limit");
        }
        Ok(())
    }
    async fn fetch(
        &self,
        client: &reqwest::Client,
        url: &reqwest::Url,
        stream: &Value,
        path: &Path,
        limit: u64,
        cache_key: &str,
        previous_bytes: u64,
        exhausted_eof: &mut bool,
    ) -> Result<(u64, String)> {
        if limit == 0 {
            return Err("media_cache_limit");
        }
        // The parent is taskd-private. Reject an existing link before opening.
        if std::fs::symlink_metadata(path).is_ok() {
            return Err("unsafe_path");
        }
        let file = files::open_private(path)?;
        let mut file = tokio::fs::File::from_std(file);
        file.set_len(0).await.map_err(|_| "storage_unavailable")?;
        let mut hash = Sha256::new();
        let mut prefix = Vec::new();
        let mut offset = 0;
        let mut total = None;
        loop {
            let end = total
                .map(|n: u64| (offset + RANGE_BYTES - 1).min(n - 1))
                .unwrap_or(RANGE_BYTES - 1);
            let mut request = client
                .get(url.clone())
                .header(reqwest::header::RANGE, format!("bytes={offset}-{end}"));
            if let Some(headers) = stream["http_headers"].as_object() {
                for (name, value) in headers {
                    if [
                        "user-agent",
                        "referer",
                        "accept",
                        "accept-language",
                        "origin",
                    ]
                    .contains(&name.to_ascii_lowercase().as_str())
                    {
                        let text = value
                            .as_str()
                            .filter(|s| s.len() <= 4096)
                            .ok_or("media_unsupported_format")?;
                        request = request.header(name, text);
                    }
                }
            }
            let mut response = match retry_connect_eof(
                || request.try_clone().expect("bodyless range request").send(),
                exhausted_eof,
            )
            .await
            {
                Ok(response) => response,
                Err(code) => {
                    #[cfg(debug_assertions)]
                    if std::env::var_os("GMGN_MEDIA_PROBE_COMPARE_CURL").is_some() {
                        compare_failed_range(url, stream, offset, end).await;
                    }
                    return Err(code);
                }
            };
            if !response.status().is_success() {
                return Err(download_http_error(response.status()));
            }
            if response
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .is_some_and(|value| {
                    let mime = value.split(';').next().unwrap_or("").trim();
                    !mime.starts_with("video/")
                        && !mime.starts_with("audio/")
                        && ![
                            "application/mp4",
                            "application/octet-stream",
                            "binary/octet-stream",
                        ]
                        .contains(&mime)
                })
            {
                return Err("media_invalid_content");
            }
            let expected = if response.status() == reqwest::StatusCode::PARTIAL_CONTENT {
                let header = response
                    .headers()
                    .get(reqwest::header::CONTENT_RANGE)
                    .and_then(|v| v.to_str().ok())
                    .ok_or("media_invalid_range")?;
                let (start, last, size) = content_range(header)?;
                if start != offset
                    || last > end
                    || total.is_some_and(|n| n != size)
                    || last < start
                    || last >= size
                {
                    return Err("media_invalid_range");
                }
                if size > limit {
                    return Err("media_cache_limit");
                }
                total = Some(size);
                last - start + 1
            } else if response.status() == reqwest::StatusCode::OK && offset == 0 {
                let size = response
                    .content_length()
                    .filter(|n| *n > 0)
                    .ok_or("media_invalid_range")?;
                if size > limit {
                    return Err("media_cache_limit");
                }
                total = Some(size);
                size
            } else {
                return Err("media_invalid_range");
            };
            if response.content_length().is_some_and(|n| n != expected) {
                return Err("media_invalid_range");
            }
            if offset == 0 {
                self.evict(
                    previous_bytes + total.ok_or("media_invalid_range")?,
                    cache_key,
                )
                .await?;
                let remaining = total.ok_or("media_invalid_range")?;
                if fs2::available_space(&self.root).map_err(|_| "storage_unavailable")?
                    < remaining + 64 * 1024 * 1024
                {
                    return Err("media_disk_full");
                }
            }
            let mut received = 0;
            while let Some(bytes) = response.chunk().await.map_err(download_error)? {
                received += bytes.len() as u64;
                if received > expected || offset + received > limit {
                    return Err("media_cache_limit");
                }
                file.write_all(&bytes)
                    .await
                    .map_err(|_| "storage_unavailable")?;
                hash.update(&bytes);
                if prefix.len() < 16 {
                    prefix.extend_from_slice(&bytes[..bytes.len().min(16 - prefix.len())]);
                }
            }
            if received != expected || received == 0 {
                return Err("media_invalid_range");
            }
            offset += received;
            if Some(offset) == total {
                break;
            }
        }
        file.sync_all().await.map_err(|_| "storage_unavailable")?;
        if prefix.len() < 16
            || &prefix[4..8] != b"ftyp"
            || u32::from_be_bytes(prefix[..4].try_into().unwrap()) < 16
            || u32::from_be_bytes(prefix[..4].try_into().unwrap()) as u64 > offset
        {
            return Err("media_invalid_content");
        }
        Ok((offset, format!("{:x}", hash.finalize())))
    }
}

async fn bounded_output<R: tokio::io::AsyncRead + Unpin>(mut stream: R) -> Result<Vec<u8>> {
    let mut output = Vec::new();
    let mut buf = [0; 8192];
    loop {
        let n = stream
            .read(&mut buf)
            .await
            .map_err(|_| "media_resolve_failed")?;
        if n == 0 {
            return Ok(output);
        }
        if output.len() + n > HELPER_OUTPUT_LIMIT {
            return Err("media_resolve_failed");
        }
        output.extend_from_slice(&buf[..n]);
    }
}
fn youtube_playlist_input(input: &Value) -> Result<(String, Option<String>, usize, usize)> {
    let url = reqwest::Url::parse(input["pageURL"].as_str().ok_or("invalid_media_input")?).map_err(|_| "invalid_media_input")?;
    if url.scheme() != "https" || !url.username().is_empty() || url.password().is_some()
        || url.port().is_some() || !matches!(url.host_str(), Some("youtube.com" | "www.youtube.com" | "m.youtube.com" | "music.youtube.com" | "youtu.be")) {
        return Err("media_unsupported_site");
    }
    let pairs: HashMap<_,_> = url.query_pairs().map(|(k,v)|(k.into_owned(),v.into_owned())).collect();
    let list = pairs.get("list").filter(|v| !v.is_empty() && v.len() <= 200 && v.bytes().all(|b|b.is_ascii_alphanumeric() || b"_-".contains(&b))).ok_or("invalid_media_input")?;
    let video = if url.host_str() == Some("youtu.be") { Some(url.path().trim_start_matches('/').to_owned()) } else { pairs.get("v").cloned() };
    if let Some(id) = &video { youtube_page(id)?; }
    if !matches!(url.path(), "/watch" | "/playlist") && url.host_str() != Some("youtu.be") { return Err("invalid_media_input"); }
    let index = pairs.get("index").map(|n|n.parse::<usize>().ok().filter(|n|*n > 0 && *n <= 10000).ok_or("invalid_media_input")).transpose()?.unwrap_or(1)-1;
    let mut canonical = reqwest::Url::parse(if video.is_some() { "https://www.youtube.com/watch" } else { "https://www.youtube.com/playlist" }).unwrap();
    { let mut query=canonical.query_pairs_mut(); if let Some(id)=&video {query.append_pair("v",id);} query.append_pair("list",list); }
    Ok((canonical.to_string(),video,index,if list.starts_with("RD") {50} else {MAX_LIST_ITEMS}))
}
fn playlist_items(metadata: &Value, video: Option<&str>, requested_index: usize, limit: usize) -> Result<(Value,usize,bool)> {
    let rows=metadata["entries"].as_array().ok_or("media_playlist_unavailable")?;
    let mut items=Vec::new();
    let mut requested_start=None;
    for (ordinal,row) in rows.iter().take(limit).enumerate() {
        // Flat extraction skips private/deleted entries; never hand arbitrary URLs to the player.
        if matches!(row["availability"].as_str(),Some("private"|"premium_only"|"subscriber_only")) {continue;}
        let Some(id)=row["id"].as_str() else {continue;};
        if let Ok(page)=youtube_page(id) {
            if ordinal >= requested_index && requested_start.is_none() {requested_start=Some(items.len());}
            items.push(json!({"pageURL":page,"maxHeight":2160}));
        }
    }
    if items.is_empty() {return Err("media_playlist_empty");}
    let index=if let Some(id)=video {
        let target=youtube_page(id)?;
        items.iter().position(|item|item["pageURL"] == target).ok_or("media_playlist_start_outside_limit")?
    } else {requested_start.ok_or("media_playlist_start_outside_limit")?};
    if index >= items.len() {return Err("media_playlist_start_outside_limit");}
    Ok((json!(items),index,rows.len()>limit))
}
async fn resolve_playlist(page: &str, limit: usize, helpers: &Helpers) -> Result<Value> {
    verify_helper(&helpers.helper,&helpers.helper_sha256)?;
    verify_helper(&helpers.deno,&helpers.deno_sha256)?;
    let mut command=tokio::process::Command::new(&helpers.helper);
    command.env_clear().args(["--ignore-config","--no-warnings","--no-color","--no-progress","--no-cache-dir","--no-update","--no-cookies","--no-js-runtimes","--yes-playlist","--flat-playlist","--skip-download","--dump-single-json","--playlist-end"])
        .arg((limit+1).to_string()).arg("--js-runtimes").arg(format!("deno:{}",helpers.deno.display()))
        .args(["--",page]).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).kill_on_drop(true);
    let mut child=command.spawn().map_err(|_|"media_helper_unavailable")?;
    let stdout=child.stdout.take().ok_or("media_resolve_failed")?;
    let stderr=child.stderr.take().ok_or("media_resolve_failed")?;
    tokio::time::timeout(Duration::from_secs(90),async {
        let (output,_,status)=tokio::try_join!(bounded_output(stdout),bounded_output(stderr),async {child.wait().await.map_err(|_|"media_resolve_failed")})?;
        if !status.success() {return Err("media_playlist_unavailable");}
        serde_json::from_slice(&output).map_err(|_|"media_resolve_failed")
    }).await.map_err(|_|"media_resolve_timeout")?
}
async fn resolve(item: &Entry, helpers: &Helpers) -> Result<Value> {
    verify_helper(&helpers.helper, &helpers.helper_sha256)?;
    verify_helper(&helpers.deno, &helpers.deno_sha256)?;
    let selector = format!(
        "bv[height<={}][vcodec^=avc1]+ba[acodec^=mp4a]/b[height<={}][vcodec^=avc1][acodec^=mp4a]",
        item.height, item.height
    );
    let mut command = tokio::process::Command::new(&helpers.helper);
    command
        .env_clear()
        .args([
            "--ignore-config",
            "--no-warnings",
            "--no-color",
            "--no-progress",
            "--no-cache-dir",
            "--no-update",
            "--no-cookies",
            "--no-js-runtimes",
            "--no-playlist",
            "--simulate",
            "--dump-single-json",
            "--js-runtimes",
        ])
        .arg(format!("deno:{}", helpers.deno.display()))
        .args(["-f", &selector, "--", &item.page])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|_| "media_helper_unavailable")?;
    let stdout = child.stdout.take().ok_or("media_resolve_failed")?;
    let stderr = child.stderr.take().ok_or("media_resolve_failed")?;
    let work = async {
        let (output, _, status) =
            tokio::try_join!(bounded_output(stdout), bounded_output(stderr), async {
                child.wait().await.map_err(|_| "media_resolve_failed")
            })?;
        if !status.success() {
            return Err("media_resolve_failed");
        }
        serde_json::from_slice(&output).map_err(|_| "media_resolve_failed")
    };
    tokio::time::timeout(Duration::from_secs(90), work)
        .await
        .map_err(|_| "media_resolve_timeout")?
}
fn codec<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v[key].as_str().filter(|s| !s.is_empty() && *s != "none")
}
fn valid_playback_range(range: &str) -> bool {
    let Some((start, end)) = range.strip_prefix("bytes=").and_then(|r| r.split_once('-')) else {
        return false;
    };
    let (Ok(start), Ok(end)) = (start.parse::<u64>(), end.parse::<u64>()) else {
        return false;
    };
    end >= start && end - start < RANGE_BYTES
}
fn source_request(
    client: &reqwest::Client,
    url: reqwest::Url,
    stream: &Value,
) -> Result<reqwest::RequestBuilder> {
    let mut request = client.get(url);
    if let Some(headers) = stream["http_headers"].as_object() {
        for (name, value) in headers {
            if [
                "user-agent",
                "referer",
                "accept",
                "accept-language",
                "origin",
            ]
            .contains(&name.to_ascii_lowercase().as_str())
            {
                let text = value
                    .as_str()
                    .filter(|s| s.len() <= 4096)
                    .ok_or("media_unsupported_format")?;
                request = request.header(name, text);
            }
        }
    }
    Ok(request)
}
fn playback_descriptor(
    item: &Entry,
    info: &Value,
    video: &Value,
    audio: Option<&Value>,
    media: &Media,
) -> Result<Value> {
    let track = |kind: &str, stream: &Value| -> Result<Value> {
        source_url(stream, media)?;
        Ok(
            json!({"url":format!("/media/{}/{kind}", item.key),"formatID":stream["format_id"],
            "container":stream["ext"],"videoCodec":codec(stream,"vcodec"),"audioCodec":codec(stream,"acodec"),
            "width":stream["width"],"height":stream["height"],"isManifest":false,
            "hasVideo":codec(stream,"vcodec").is_some(),"hasAudio":codec(stream,"acodec").is_some(),"headers":{}}),
        )
    };
    Ok(
        json!({"pageURL":item.page,"site":if item.page.contains("bilibili.com") {"bilibili"} else {"youtube"},
        "title":info["title"].as_str().unwrap_or(""),"durationSeconds":info["duration"],"isLive":false,
        "video":track("video",video)?,"audio":audio.map(|a|track("audio",a)).transpose()?}),
    )
}
fn streams(info: &Value, height: u32) -> Result<(Value, Option<Value>)> {
    if info["is_live"].as_bool() == Some(true)
        || matches!(
            info["live_status"].as_str(),
            Some("is_live" | "is_upcoming" | "post_live")
        )
    {
        return Err("media_live_unsupported");
    }
    if info["has_drm"].as_bool() == Some(true)
        || info["age_limit"].as_u64().is_some_and(|n| n > 0)
        || info["availability"]
            .as_str()
            .is_some_and(|s| !["public", "unlisted"].contains(&s))
    {
        return Err("media_restricted");
    }
    let formats = info["requested_formats"]
        .as_array()
        .cloned()
        .unwrap_or_else(|| vec![info.clone()]);
    let video = formats
        .iter()
        .find(|v| codec(v, "vcodec").is_some())
        .cloned()
        .ok_or("media_unsupported_format")?;
    let audio = if codec(&video, "acodec").is_some() {
        None
    } else {
        Some(
            formats
                .iter()
                .find(|v| codec(v, "vcodec").is_none() && codec(v, "acodec").is_some())
                .cloned()
                .ok_or("media_unsupported_format")?,
        )
    };
    let vcodec = codec(&video, "vcodec").ok_or("media_unsupported_format")?;
    let acodec =
        codec(audio.as_ref().unwrap_or(&video), "acodec").ok_or("media_unsupported_format")?;
    if video["ext"] != "mp4"
        || !(vcodec.starts_with("avc1") || vcodec == "h264")
        || !(acodec.starts_with("mp4a") || acodec == "aac")
        || video["height"].as_u64().is_none_or(|n| n > height as u64)
    {
        return Err("media_unsupported_format");
    }
    for stream in std::iter::once(&video).chain(audio.as_ref()) {
        if stream["has_drm"].as_bool() == Some(true) {
            return Err("media_restricted");
        }
        if !matches!(stream["ext"].as_str(), Some("mp4" | "m4a"))
            || stream["protocol"]
                .as_str()
                .is_some_and(|p| !matches!(p, "http" | "https"))
        {
            return Err("media_unsupported_format");
        }
    }
    // Copy only non-credential request headers; top-level headers apply to both
    // tracks when the extractor omitted a track-specific dictionary.
    let mut video = video;
    let mut audio = audio;
    for stream in std::iter::once(&mut video).chain(audio.as_mut()) {
        if stream.get("http_headers").is_none() {
            stream["http_headers"] = info["http_headers"].clone();
        }
    }
    Ok((video, audio))
}
fn source_url(stream: &Value, media: &Media) -> Result<reqwest::Url> {
    let url = reqwest::Url::parse(stream["url"].as_str().ok_or("media_unsupported_format")?)
        .map_err(|_| "media_unsupported_format")?;
    #[cfg(test)]
    if media.allow_test_sources
        && matches!(url.scheme(), "http" | "https")
        && url.host_str() == Some("127.0.0.1")
    {
        return Ok(url);
    }
    let _ = media;
    if !public_source_url(&url) {
        return Err("media_unsupported_format");
    }
    Ok(url)
}
fn download_client_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if redirect_allowed(attempt.url(), attempt.previous().len()) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(60))
}
fn redirect_allowed(url: &reqwest::Url, previous_requests: usize) -> bool {
    // The first redirect already has one previous request: permit two hops.
    previous_requests < 3 && public_source_url(url)
}
fn public_source_url(url: &reqwest::Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    let allowed = [
        "googlevideo.com",
        "youtube.com",
        "bilivideo.com",
        "bilivideo.cn",
        "hdslb.com",
    ]
    .iter()
    .any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")));
    allowed
        && url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
}
// Never expose reqwest's Display/source: those can contain signed source URLs.
fn connect_eof(error: &reqwest::Error) -> bool {
    use std::error::Error;
    if !error.is_connect() {
        return false;
    }
    let mut cause = error.source();
    while let Some(value) = cause {
        if value
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::UnexpectedEof)
            || value.to_string().eq_ignore_ascii_case("tls handshake eof")
        {
            return true;
        }
        cause = value.source();
    }
    false
}
async fn retry_connect_eof<T, F, Fut>(mut send: F, exhausted_eof: &mut bool) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = std::result::Result<T, reqwest::Error>>,
{
    *exhausted_eof = false;
    // At most three attempts of the same idempotent request, before any body
    // bytes are committed. The worker's existing 600s deadline/cancel encloses
    // this future. HTTP responses and body failures never enter this retry.
    for attempt in 0..3 {
        match send().await {
            Ok(value) => return Ok(value),
            Err(error) if attempt < 2 && connect_eof(&error) => {}
            Err(error) => {
                *exhausted_eof = attempt == 2 && connect_eof(&error);
                if error.is_connect() {
                    eprintln!(
                        "media download connect failure: attempts={}, tls_eof={}",
                        attempt + 1,
                        connect_eof(&error)
                    );
                    use std::error::Error;
                    let mut cause = error.source();
                    while let Some(value) = cause {
                        let text = value.to_string().to_ascii_lowercase();
                        let labels: Vec<_> = [
                            "certificate",
                            "tls",
                            "ssl",
                            "dns",
                            "resolve",
                            "proxy",
                            "tunnel",
                            "closed",
                            "eof",
                            "refused",
                            "reset",
                            "timed out",
                        ]
                        .into_iter()
                        .filter(|label| text.contains(label))
                        .collect();
                        eprintln!("media download connect cause categories: {:?}", labels);
                        if let Some(io) = value.downcast_ref::<std::io::Error>() {
                            eprintln!("media download connect cause kind: {:?}", io.kind());
                        }
                        cause = value.source();
                    }
                }
                return Err(download_error(error));
            }
        }
    }
    unreachable!()
}
#[cfg(debug_assertions)]
async fn compare_failed_range(url: &reqwest::Url, stream: &Value, start: u64, end: u64) {
    let mut command = tokio::process::Command::new("/usr/bin/curl");
    command.args([
        "--silent",
        "--max-time",
        "20",
        "--connect-timeout",
        "10",
        "--max-filesize",
        "1024",
        "--output",
        "/dev/null",
        "--write-out",
        "%{http_code} %{size_download}",
    ]);
    #[cfg(target_os = "macos")]
    if let Ok(output) = tokio::process::Command::new("/usr/sbin/scutil")
        .arg("--proxy")
        .output()
        .await
    {
        let text = String::from_utf8_lossy(&output.stdout);
        let field = |key: &str| {
            text.lines()
                .filter_map(|line| line.trim().split_once(" : "))
                .find_map(|(name, value)| (name == key).then_some(value))
        };
        if field("HTTPSEnable") == Some("1") {
            if let (Some(host), Some(port)) = (field("HTTPSProxy"), field("HTTPSPort")) {
                command.args(["--proxy", &format!("http://{host}:{port}"), "--noproxy", ""]);
            }
        }
    }
    command.args(["--range", &format!("{start}-{end}")]);
    if let Some(headers) = stream["http_headers"].as_object() {
        for (name, value) in headers {
            if [
                "user-agent",
                "referer",
                "accept",
                "accept-language",
                "origin",
            ]
            .contains(&name.to_ascii_lowercase().as_str())
            {
                if let Some(text) = value.as_str() {
                    command.args(["--header", &format!("{name}: {text}")]);
                }
            }
        }
    }
    command.args(["--", url.as_str()]).kill_on_drop(true);
    // Deliberately discard stderr: curl errors can contain source addresses.
    if let Ok(Ok(output)) = tokio::time::timeout(Duration::from_secs(25), command.output()).await {
        let value = String::from_utf8_lossy(&output.stdout);
        if value
            .chars()
            .all(|ch| ch.is_ascii_digit() || ch.is_ascii_whitespace())
        {
            eprintln!(
                "media download connect curl same-url-range: exit={}, http_bytes={}",
                output.status.code().unwrap_or(-1),
                value.trim()
            );
        }
    }
}
fn download_error(error: reqwest::Error) -> &'static str {
    if error.is_timeout() {
        "media_download_timeout"
    } else if error.is_connect() {
        "media_download_connect"
    } else if error.is_body() || error.is_decode() {
        "media_download_body"
    } else {
        "media_download_transport"
    }
}

fn download_http_error(status: reqwest::StatusCode) -> &'static str {
    match status.as_u16() {
        401 => "media_download_http_401",
        403 => "media_download_http_403",
        404 => "media_download_http_404",
        429 => "media_download_http_429",
        500..=599 => "media_download_http_5xx",
        _ => "media_download_http_status",
    }
}

fn content_range(value: &str) -> Result<(u64, u64, u64)> {
    let (range, size) = value
        .strip_prefix("bytes ")
        .and_then(|s| s.split_once('/'))
        .ok_or("media_invalid_range")?;
    let (start, end) = range.split_once('-').ok_or("media_invalid_range")?;
    Ok((
        start.parse().map_err(|_| "media_invalid_range")?,
        end.parse().map_err(|_| "media_invalid_range")?,
        size.parse().map_err(|_| "media_invalid_range")?,
    ))
}

fn verify_helper(path: &Path, expected: &str) -> Result<()> {
    if !path.is_absolute()
        || expected.len() != 64
        || !expected.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err("invalid_media_helper_config");
    }
    let metadata = std::fs::symlink_metadata(path).map_err(|_| "media_helper_unavailable")?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err("media_helper_unavailable");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o111 == 0 {
            return Err("media_helper_unavailable");
        }
    }
    if hash_file(path)? != expected.to_lowercase() {
        return Err("media_helper_integrity_failed");
    }
    Ok(())
}
fn hash_file(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).map_err(|_| "media_cache_missing")?;
    let mut hash = Sha256::new();
    let mut buf = [0; 65536];
    loop {
        let n = file.read(&mut buf).map_err(|_| "media_cache_missing")?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
fn descriptor_files_valid(root: &Path, descriptor: &Value, hash: bool) -> Result<bool> {
    for kind in ["video", "audio"] {
        let Some(track) = descriptor.get(kind).filter(|v| !v.is_null()) else {
            continue;
        };
        let url = reqwest::Url::parse(track["url"].as_str().ok_or("media_storage_corrupt")?)
            .map_err(|_| "media_storage_corrupt")?;
        let path = url.to_file_path().map_err(|_| "media_storage_corrupt")?;
        if path.parent() != Some(root) {
            return Err("media_storage_corrupt");
        }
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            return Ok(false);
        };
        if !metadata.is_file()
            || metadata.file_type().is_symlink()
            || Some(metadata.len()) != track["bytes"].as_u64()
        {
            return Ok(false);
        }
        if hash && Some(hash_file(&path)?.as_str()) != track["sha256"].as_str() {
            return Ok(false);
        }
    }
    Ok(descriptor.get("video").is_some_and(|v| !v.is_null()))
}
fn fingerprint(root: &Path, descriptor: &Value) -> Result<Vec<(PathBuf, u64, SystemTime)>> {
    let mut result = Vec::new();
    for kind in ["video", "audio"] {
        if let Some(track) = descriptor.get(kind).filter(|v| !v.is_null()) {
            let path = reqwest::Url::parse(track["url"].as_str().ok_or("media_storage_corrupt")?)
                .map_err(|_| "media_storage_corrupt")?
                .to_file_path()
                .map_err(|_| "media_storage_corrupt")?;
            if path.parent() != Some(root) {
                return Err("unsafe_path");
            }
            let metadata = std::fs::symlink_metadata(&path).map_err(|_| "media_cache_missing")?;
            result.push((
                path,
                metadata.len(),
                metadata.modified().map_err(|_| "media_cache_missing")?,
            ));
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::{
        io::{AsyncBufReadExt, BufReader},
        net::TcpListener,
    };
    #[test]
    fn malformed_sidx_never_panics_or_accepts_truncated_index() {
        assert!(mp4_segment_index(b"\0\0\0\x08sidx").is_err());
        let mut index = vec![0; 44];
        index[0..4].copy_from_slice(&44u32.to_be_bytes());
        index[4..8].copy_from_slice(b"sidx");
        index[16..20].copy_from_slice(&1000u32.to_be_bytes());
        index[30..32].copy_from_slice(&1u16.to_be_bytes());
        index[32..36].copy_from_slice(&100u32.to_be_bytes());
        index[36..40].copy_from_slice(&5000u32.to_be_bytes());
        let parsed = mp4_segment_index(&index).unwrap().unwrap();
        assert_eq!(parsed.first_offset, 44);
        assert_eq!(parsed.segments, vec![(44, 100, 5.0)]);
        index[0..4].copy_from_slice(&32u32.to_be_bytes());
        assert!(mp4_segment_index(&index).is_err());
        index[0..4].copy_from_slice(&44u32.to_be_bytes());
        index[8] = 1;
        assert!(mp4_segment_index(&index).is_err());
    }
    #[tokio::test]
    #[ignore = "opt-in silent native consumer fixture; requires GMGN_MEDIA_FIXTURE_INFO with isolated local source"]
    async fn native_consumer_streaming_http_fixture() {
        let info_path = std::env::var("GMGN_MEDIA_FIXTURE_INFO").expect("isolated info path");
        let info: Value = serde_json::from_slice(&std::fs::read(info_path).unwrap()).unwrap();
        let mut fixture = Fixture::new("normal", 64, ITEM_LIMIT, CACHE_LIMIT).await;
        std::fs::write(
            &fixture.helpers.helper,
            format!(
                "#!/bin/sh\nprintf '%s' '{}'\n",
                info.to_string().replace('\'', "'\\''")
            ),
        )
        .unwrap();
        fixture.helpers.helper_sha256 = format!(
            "{:x}",
            Sha256::digest(std::fs::read(&fixture.helpers.helper).unwrap())
        );
        fixture
            .media
            .initialize(Some(fixture.helpers.clone()))
            .await
            .unwrap();
        let mut service = crate::daemon::Service::new(fixture.media.db.clone()).unwrap();
        service.media = fixture.media.clone();
        let token = uuid::Uuid::new_v4().to_string();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let http = crate::http::HttpService::new(service, token.clone());
        let server = tokio::spawn(async move {
            loop {
                let (socket, _) = listener.accept().await.unwrap();
                let http = http.clone();
                tokio::spawn(async move {
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(
                            hyper_util::rt::TokioIo::new(socket),
                            hyper::service::service_fn(move |request| {
                                let http = http.clone();
                                async move { http.handle(request).await }
                            }),
                        )
                        .await;
                });
            }
        });
        let endpoint = fixture.root.join("taskd.endpoint.json");
        std::fs::write(
            &endpoint,
            json!({"version":2,"address":address.to_string(),"token":token}).to_string(),
        )
        .unwrap();
        let mut probe = tokio::process::Command::new("swift");
        probe
            .args([
                "tools/probe-native-link-playback.swift",
                "https://www.youtube.com/watch?v=abcdefghijk",
                "20",
            ])
            .current_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."))
            .env("GMGN_MEDIA_CACHE_ENDPOINT", endpoint)
            .env("GMGN_NATIVE_LINK_SILENT", "1")
            .env("GMGN_CACHE_FIRST_FRAME_TIMEOUT", "30");
        if info["is_live"] == true {
            probe.env("GMGN_CACHE_LIVE_FIXTURE", "1");
        }
        let observed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let completed = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let media = fixture.media.clone();
        let observed_monitor = observed.clone();
        let completed_monitor = completed.clone();
        let expected = if info["is_live"] == true {
            "streaming"
        } else {
            "downloading"
        };
        let item = entry(&json!({"pageURL":"https://youtu.be/abcdefghijk"})).unwrap();
        let monitor = tokio::spawn(async move {
            loop {
                if let Ok(status) = media.status(&item.key).await {
                    if status["state"] == expected {
                        observed_monitor.store(true, Ordering::SeqCst);
                    }
                    if status["state"] == "ready" {
                        completed_monitor.store(true, Ordering::SeqCst);
                    }
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        });
        let result = tokio::time::timeout(Duration::from_secs(150), probe.status())
            .await
            .unwrap()
            .unwrap();
        monitor.abort();
        server.abort();
        assert!(result.success(), "native consumer fixture failed");
        assert!(
            fixture
                .media
                .state
                .lock()
                .await
                .owners
                .values()
                .all(|owners| owners.is_empty()),
            "native consumer did not release media owner"
        );
        if info["is_live"] == true {
            assert!(
                fixture.media.live_resources.lock().await.is_empty(),
                "live capabilities survived consumer release"
            );
        }
        assert!(
            observed.load(Ordering::SeqCst),
            "producer did not expose early playable state"
        );
        assert!(
            !completed.load(Ordering::SeqCst),
            "fixture completed caching before playback observation ended"
        );
        println!("rust_producer_early_playback=true completed_cache_during_observation=false released_owners=true");
    }
    #[tokio::test]
    async fn playback_range_available_before_complete_cache_and_signed_urls_are_not_persisted() {
        let f = Fixture::new("slow", RANGE_BYTES as usize * 2, ITEM_LIMIT, CACHE_LIMIT).await;
        let prepared = f.prepare("abcdefghijk", "screen").await;
        let key = prepared["cacheKey"].as_str().unwrap();
        let status = loop {
            let status = f.media.status(key).await.unwrap();
            if status["state"] == "downloading" {
                break status;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        };
        assert_eq!(
            status["streamingDescriptor"]["video"]["url"],
            format!("/media/{key}/video")
        );
        assert!(!status.to_string().contains("127.0.0.1"));
        assert!(!f.media.root.join(format!("{key}.video.mp4")).exists());
        let response = f
            .media
            .playback_range(key, "video", "bytes=0-31")
            .await
            .unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::PARTIAL_CONTENT);
        assert_eq!(response.bytes().await.unwrap().as_ref(), &f.bytes[..32]);
        assert!(f
            .media
            .playback_range(key, "video", "bytes=0-1048576")
            .await
            .is_err());
        assert!(f
            .media
            .playback_range(key, "../video", "bytes=0-31")
            .await
            .is_err());
        assert_eq!(f.terminal(key).await["state"], "ready");
        let stored = f
            .media
            .db
            .call(move |db| {
                let value: String = db
                    .connection
                    .query_row("SELECT payload FROM media_cache", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")?;
                Ok(value)
            })
            .await
            .unwrap();
        assert!(!stored.contains("http://"));
    }
    #[tokio::test]
    async fn playback_rejects_wrong_range_and_bounded_hls_resource_registration() {
        let f = Fixture::new("wrong_range", 64, ITEM_LIMIT, CACHE_LIMIT).await;
        let item = entry(&json!({"pageURL":"https://youtu.be/abcdefghijk"})).unwrap();
        let info = resolve(&item, &f.helpers).await.unwrap();
        f.media
            .playback_sources
            .lock()
            .await
            .insert(item.key.clone(), json!({"video":info}));
        assert_eq!(
            f.media
                .playback_range(&item.key, "video", "bytes=0-31")
                .await
                .unwrap_err(),
            "media_invalid_range"
        );
        let base = reqwest::Url::parse("https://manifest.googlevideo.com/live.m3u8").unwrap();
        let cap = uuid::Uuid::new_v4().to_string();
        let parent = json!({"http_headers":{"User-Agent":"fixture"}});
        let first = f
            .media
            .register_live_uri(&cap, &base, "segment.ts?signature=private", &parent)
            .await
            .unwrap();
        assert_eq!(
            first,
            f.media
                .register_live_uri(&cap, &base, "segment.ts?signature=private", &parent)
                .await
                .unwrap()
        );
        assert_eq!(f.media.live_resources.lock().await.len(), 1);
        assert!(!first.contains("private"));
        assert!(f
            .media
            .register_live_uri(&cap, &base, "https://evil.invalid/private", &parent)
            .await
            .is_err());
        let mut resources = f.media.live_resources.lock().await;
        resources
            .get_mut(first.trim_start_matches("/media-live/"))
            .unwrap()["_registeredAt"] = json!(now() - 601);
        drop(resources);
        f.media
            .register_live_uri(&cap, &base, "new.ts", &parent)
            .await
            .unwrap();
        assert_eq!(f.media.live_resources.lock().await.len(), 1);
    }
    #[tokio::test]
    async fn live_hls_rewrites_manifest_and_segment_and_revokes_on_release() {
        let f = Fixture::new("normal", 64, ITEM_LIMIT, CACHE_LIMIT).await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                tokio::spawn(async move {
                    let mut request = [0u8; 2048];
                    let n = socket.read(&mut request).await.unwrap();
                    let request = String::from_utf8_lossy(&request[..n]);
                    let body = if request.contains("/live.m3u8") {
                        b"#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment.ts\n".as_slice()
                    } else {
                        b"live segment bytes".as_slice()
                    };
                    socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len()).as_bytes()).await.unwrap();
                    socket.write_all(body).await.unwrap();
                });
            }
        });
        let item = entry(&json!({"pageURL":"https://youtu.be/abcdefghijk"})).unwrap();
        // Create the durable state row, without scheduling the fixture helper.
        let k = item.key.clone();
        f.media.db.call(move|db|{db.connection.execute("INSERT INTO media_cache(cache_key,page_url,height,state,payload,last_used)VALUES(?1,'public',2160,'resolving','{}',0)",[k]).map_err(|_|"storage_unavailable")?;Ok(())}).await.unwrap();
        let info = json!({"is_live":true,"availability":"public","title":"live","formats":[{"url":format!("http://{addr}/live.m3u8"),"height":2160,"width":3840,"format_id":"hls","vcodec":"avc1.640033","acodec":"mp4a.40.2","protocol":"m3u8_native"}]});
        let (descriptor, bytes) = f.media.prepare_live(&item, &info).await.unwrap();
        assert_eq!(bytes, 0);
        assert_eq!(descriptor["isLive"], true);
        let status = f.media.status(&item.key).await.unwrap();
        assert_eq!(status["state"], "streaming");
        let path = descriptor["video"]["url"].as_str().unwrap();
        let parts: Vec<_> = path.split('/').collect();
        let (mime, body) = f.media.live_resource(parts[2], parts[3]).await.unwrap();
        assert_eq!(mime, "application/vnd.apple.mpegurl");
        let body = String::from_utf8(body).unwrap();
        assert!(!body.contains(&addr.to_string()));
        assert!(!body.contains("ENDLIST"));
        let segment = body
            .lines()
            .find(|line| line.starts_with("/media-live/"))
            .unwrap();
        let sub: Vec<_> = segment.split('/').collect();
        assert_eq!(
            f.media.live_resource(sub[2], sub[3]).await.unwrap().1,
            b"live segment bytes"
        );
        f.media
            .request(
                "media_release",
                json!({"cacheKey":item.key,"consumerID":"screen"}),
            )
            .await
            .unwrap();
        assert!(f.media.live_resource(parts[2], parts[3]).await.is_err());
        server.abort();
    }

    struct Fixture {
        root: PathBuf,
        media: Arc<Media>,
        helpers: Helpers,
        bytes: Vec<u8>,
        requests: Arc<AtomicUsize>,
        server: tokio::task::JoinHandle<()>,
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            self.server.abort();
        }
    }
    impl Fixture {
        async fn new(mode: &str, size: usize, item_limit: u64, cache_limit: u64) -> Self {
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("gmgn-media-{}", uuid::Uuid::new_v4()));
            files::directory(&root).unwrap();
            let mut bytes = (0..size).map(|n| (n % 251) as u8).collect::<Vec<_>>();
            if bytes.len() >= 24 {
                bytes[..24].copy_from_slice(b"\0\0\0\x18ftypisom\0\0\0\0isommp42");
            }
            if bytes.len() >= 32 {
                // A valid bounded box follows ftyp. Random bytes here used to
                // look like an oversized box and fail the new sidx reader.
                let length=(bytes.len()-24) as u32;
                bytes[24..28].copy_from_slice(&length.to_be_bytes());
                bytes[28..32].copy_from_slice(b"mdat");
            }
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let requests = Arc::new(AtomicUsize::new(0));
            let requests_inner = requests.clone();
            let data = bytes.clone();
            let mode = mode.to_owned();
            let helper_mode = mode.clone();
            let server = tokio::spawn(async move {
                loop {
                    let (stream, _) = listener.accept().await.unwrap();
                    let bytes = data.clone();
                    let requests = requests_inner.clone();
                    let mode = mode.clone();
                    tokio::spawn(async move {
                        let mut stream = stream;
                        if mode.starts_with("source_eof") {
                            let mut first = [0u8; 1];
                            stream.peek(&mut first).await.unwrap();
                            if first[0] == 22 {
                                requests.fetch_add(1, Ordering::SeqCst);
                                let mut header = [0u8; 5];
                                stream.read_exact(&mut header).await.unwrap();
                                let mut body =
                                    vec![0; u16::from_be_bytes([header[3], header[4]]) as usize];
                                stream.read_exact(&mut body).await.unwrap();
                                stream.shutdown().await.unwrap();
                                return;
                            }
                        }
                        let mut reader = BufReader::new(stream);
                        let mut line = String::new();
                        reader.read_line(&mut line).await.unwrap();
                        let mut range = None;
                        loop {
                            line.clear();
                            reader.read_line(&mut line).await.unwrap();
                            if line == "\r\n" {
                                break;
                            }
                            if let Some((name, value)) = line.trim().split_once(':') {
                                if name.eq_ignore_ascii_case("range") {
                                    range = Some(value.trim().to_owned());
                                }
                            }
                        }
                        requests.fetch_add(1, Ordering::SeqCst);
                        if let Some(code) = mode.strip_prefix("http_") {
                            let socket = reader.get_mut();
                            let _ = socket.write_all(format!("HTTP/1.1 {code} Error\r\nContent-Type: text/html\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await;
                            return;
                        }
                        let range = range.unwrap();
                        let (start, end) = range
                            .strip_prefix("bytes=")
                            .unwrap()
                            .split_once('-')
                            .unwrap();
                        let start: usize = start.parse().unwrap();
                        let end: usize = end.parse().unwrap();
                        let end = end.min(bytes.len() - 1);
                        let data = &bytes[start..=end];
                        let echoed = if mode == "wrong_range" {
                            start + 1
                        } else {
                            start
                        };
                        let mime = if mode == "html" {
                            "text/html"
                        } else {
                            "video/mp4"
                        };
                        let header=format!("HTTP/1.1 206 Partial Content\r\nContent-Type: {mime}\r\nContent-Range: bytes {echoed}-{end}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",bytes.len(),data.len());
                        let socket = reader.get_mut();
                        if socket.write_all(header.as_bytes()).await.is_err() {
                            return;
                        }
                        if mode == "truncated" {
                            let _ = socket.write_all(&data[..data.len() / 2]).await;
                            return;
                        }
                        for chunk in data.chunks(16384) {
                            if mode == "slow" {
                                tokio::time::sleep(Duration::from_millis(20)).await;
                            }
                            if socket.write_all(chunk).await.is_err() {
                                return;
                            }
                        }
                    });
                }
            });
            let helper = root.join("yt-dlp");
            let deno = root.join("deno");
            let count = root.join("helper-count");
            let info = json!({"url":format!("http://{address}/media"),"title":"fixture title","duration":12,
                "vcodec":"avc1.640033","acodec":"mp4a.40.2","ext":"mp4","height":2160,"width":3840,
                "format_id":"muxed","protocol":"http","is_live":false,"availability":"public"});
            std::fs::write(
                &helper,
                format!(
                    "#!/bin/sh\nprintf x >> '{}'\nprintf '%s' '{}'\n",
                    count.display(),
                    info
                ),
            )
            .unwrap();
            if helper_mode.starts_with("source_eof") {
                let mut video = info.clone();
                video["acodec"] = json!("none");
                let mut audio = info.clone();
                audio["vcodec"] = json!("none");
                audio["url"] = json!(format!("https://{address}/media"));
                audio["ext"] = json!("m4a");
                audio["protocol"] = json!("https");
                let mut broken = info.clone();
                broken["requested_formats"] = json!([video, audio]);
                let condition = if helper_mode == "source_eof_always" {
                    "-ge"
                } else {
                    "-eq"
                };
                std::fs::write(&helper,format!("#!/bin/sh\nprintf x >> '{}'\nif [ $(/usr/bin/wc -c < '{}') {condition} 1 ]; then printf '%s' '{}'; else printf '%s' '{}'; fi\n",count.display(),count.display(),broken,info)).unwrap();
            }
            if helper_mode == "playlist" {
                let metadata=json!({"title":"fixture list","entries":[{"id":"aaaaaaaaaaa"},{"id":"bbbbbbbbbbb"},{"id":"ccccccccccc"}]});
                std::fs::write(&helper,format!("#!/bin/sh\nprintf x >> '{}'\ncase \" $* \" in *' --flat-playlist '*) printf '%s' '{}' ;; *) printf '%s' '{}' ;; esac\n",count.display(),metadata,info)).unwrap();
            }
            std::fs::write(&deno, "#!/bin/sh\nexit 0\n").unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                for path in [&helper, &deno] {
                    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
                }
            }
            let helpers = Helpers {
                helper_sha256: hash_file(&helper).unwrap(),
                deno_sha256: hash_file(&deno).unwrap(),
                helper,
                deno,
            };
            let db = Database::open(root.clone(), None).unwrap();
            let media = Arc::new(Media {
                root: root.join("media-cache"),
                db,
                state: Mutex::new(State::default()),
                playlist_lock: Mutex::new(()),
                validated: Mutex::new(HashMap::new()),
                entry_locks: Mutex::new(HashMap::new()),
                playback_sources: Mutex::new(HashMap::new()),
                live_resources: Mutex::new(HashMap::new()),
                playback_client: Mutex::new(None),
                item_limit,
                cache_limit,
                allow_test_sources: true,
            });
            media.initialize(Some(helpers.clone())).await.unwrap();
            Self {
                root,
                media,
                helpers,
                bytes,
                requests,
                server,
            }
        }
        async fn prepare(&self, id: &str, owner: &str) -> Value {
            self.media.request("media_prepare",json!({"pageURL":format!("https://youtu.be/{id}"),"maxHeight":2160,"consumerID":owner})).await.unwrap()
        }
        async fn terminal(&self, key: &str) -> Value {
            let mut last = Value::Null;
            for _ in 0..300 {
                let value = self
                    .media
                    .request("media_status", json!({"cacheKey":key}))
                    .await
                    .unwrap();
                if ["ready", "failed", "cancelled", "interrupted"]
                    .contains(&value["state"].as_str().unwrap_or(""))
                {
                    return value;
                }
                last = value;
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            panic!(
                "media job did not reach a terminal state: root={} last={last}",
                self.root.display()
            );
        }
        fn helper_calls(&self) -> usize {
            std::fs::read(self.root.join("helper-count"))
                .unwrap_or_default()
                .len()
        }
    }

    #[tokio::test]
    async fn exhausted_audio_tls_eof_refreshes_both_tracks_once_and_cleans_parts() {
        for (mode, expected) in [
            ("source_eof_once", "ready"),
            ("source_eof_always", "failed"),
        ] {
            let f = Fixture::new(mode, 128, ITEM_LIMIT, CACHE_LIMIT).await;
            let queued = f.prepare("abcdefghijk", "screen").await;
            let result = f.terminal(queued["cacheKey"].as_str().unwrap()).await;
            assert_eq!(result["state"], expected);
            assert_eq!(f.helper_calls(), 2);
            let paths: Vec<_> = std::fs::read_dir(f.root.join("media-cache"))
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .collect();
            assert!(paths
                .iter()
                .all(|path| path.extension().and_then(|ext| ext.to_str()) != Some("part")));
            if expected == "ready" {
                assert_eq!(result["descriptor"]["video"]["bytes"], 128);
                assert!(result["descriptor"]["audio"].is_null());
                assert_eq!(paths.len(), 1);
                assert_eq!(f.requests.load(Ordering::SeqCst), 5);
                f.media
                    .set_state(queued["cacheKey"].as_str().unwrap(), "resolving", None)
                    .await
                    .unwrap();
                let bytes = f
                    .media
                    .db
                    .call(|store| {
                        Ok(store
                            .connection
                            .query_row("SELECT bytes FROM media_cache", [], |row| {
                                row.get::<_, i64>(0)
                            })
                            .unwrap())
                    })
                    .await
                    .unwrap();
                assert_eq!(bytes, 0);
            } else {
                assert_eq!(result["error"], "media_download_connect");
                assert!(paths.is_empty());
                assert_eq!(f.requests.load(Ordering::SeqCst), 8);
            }
        }
    }

    #[tokio::test]
    async fn range_download_hash_cache_hit_and_restart_are_real() {
        let f = Fixture::new("normal", 2 * 1024 * 1024 + 123, ITEM_LIMIT, CACHE_LIMIT).await;
        let queued = f.prepare("abcdefghijk", "screen-a").await;
        let key = queued["cacheKey"].as_str().unwrap();
        let second = f.prepare("abcdefghijk", "screen-b").await;
        assert_eq!(second["cacheKey"], key);
        let ready = f.terminal(key).await;
        assert_eq!(ready["state"], "ready", "{ready}");
        let track = &ready["descriptor"]["video"];
        assert_eq!(track["bytes"], f.bytes.len());
        assert_eq!(track["sha256"], format!("{:x}", Sha256::digest(&f.bytes)));
        assert_eq!(f.requests.load(Ordering::SeqCst), 3);
        assert_eq!(f.helper_calls(), 1);
        assert_eq!(f.prepare("abcdefghijk", "screen-a").await["state"], "ready");
        assert_eq!(f.helper_calls(), 1);
        // A new authority-side manager uses persisted metadata/files, with no
        // helper configured: a hit still works and performs no source request.
        let db = Database::open(f.root.clone(), None).unwrap();
        let restarted = Media::new(db);
        restarted.initialize(None).await.unwrap();
        assert_eq!(restarted.request("media_prepare",json!({"pageURL":"https://www.youtube.com/watch?v=abcdefghijk","maxHeight":2160})).await.unwrap()["state"],"ready");
        assert_eq!(f.helper_calls(), 1);
        let path = reqwest::Url::parse(track["url"].as_str().unwrap())
            .unwrap()
            .to_file_path()
            .unwrap();
        let mut corrupt = f.bytes.clone();
        corrupt[0] ^= 1;
        std::fs::write(&path, corrupt).unwrap();
        assert_eq!(
            restarted
                .request("media_status", json!({"cacheKey":key}))
                .await
                .unwrap()["state"],
            "interrupted"
        );
    }

    #[tokio::test]
    async fn wrong_range_truncated_eof_and_item_limit_never_publish_ready() {
        for (mode, limit, expected) in [
            ("wrong_range", ITEM_LIMIT, "media_invalid_range"),
            ("truncated", ITEM_LIMIT, "media_download_body"),
            ("normal", 32, "media_cache_limit"),
        ] {
            let f = Fixture::new(mode, 128, limit, CACHE_LIMIT).await;
            let value = f.prepare("abcdefghijk", "screen").await;
            let value = f.terminal(value["cacheKey"].as_str().unwrap()).await;
            assert_eq!(value["state"], "failed", "{value}");
            assert_eq!(value["error"], expected);
            assert!(value.get("descriptor").is_none());
            assert!(std::fs::read_dir(f.root.join("media-cache"))
                .unwrap()
                .next()
                .is_none());
        }
    }

    #[tokio::test]
    async fn eof_retry_recovers_after_two_failures_stops_at_three_and_cancels() {
        async fn eof_error() -> reqwest::Error {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut header = [0u8; 5];
                socket.read_exact(&mut header).await.unwrap();
                let length = u16::from_be_bytes([header[3], header[4]]) as usize;
                let mut body = vec![0; length];
                socket.read_exact(&mut body).await.unwrap();
                socket.shutdown().await.unwrap();
            });
            let error = download_client_builder()
                .no_proxy()
                .build()
                .unwrap()
                .get(format!("https://{address}/"))
                .send()
                .await
                .unwrap_err();
            server.await.unwrap();
            assert!(connect_eof(&error));
            error
        }
        let mut outcomes: VecDeque<std::result::Result<(), reqwest::Error>> =
            VecDeque::from([Err(eof_error().await), Err(eof_error().await), Ok(())]);
        let mut attempts = 0;
        let mut exhausted = false;
        let result = retry_connect_eof(
            || {
                attempts += 1;
                std::future::ready(outcomes.pop_front().unwrap())
            },
            &mut exhausted,
        )
        .await;
        assert_eq!(result, Ok(()));
        assert_eq!(attempts, 3);
        assert!(!exhausted);
        let mut outcomes: VecDeque<std::result::Result<(), reqwest::Error>> = VecDeque::from([
            Err(eof_error().await),
            Err(eof_error().await),
            Err(eof_error().await),
        ]);
        let mut attempts = 0;
        assert_eq!(
            retry_connect_eof(
                || {
                    attempts += 1;
                    std::future::ready(outcomes.pop_front().unwrap())
                },
                &mut exhausted
            )
            .await,
            Err("media_download_connect")
        );
        assert_eq!(attempts, 3);
        assert!(exhausted);
        let attempts = Arc::new(AtomicUsize::new(0));
        let count = attempts.clone();
        let task = tokio::spawn(async move {
            let mut exhausted = false;
            retry_connect_eof(
                || {
                    count.fetch_add(1, Ordering::SeqCst);
                    std::future::pending::<std::result::Result<(), reqwest::Error>>()
                },
                &mut exhausted,
            )
            .await
        });
        tokio::task::yield_now().await;
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert_eq!(attempts.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn http_failures_publish_only_safe_stable_codes() {
        for (mode, expected) in [
            ("http_403", "media_download_http_403"),
            ("http_503", "media_download_http_5xx"),
            ("http_429", "media_download_http_429"),
        ] {
            let f = Fixture::new(mode, 128, ITEM_LIMIT, CACHE_LIMIT).await;
            let value = f.prepare("abcdefghijk", "screen").await;
            let value = f.terminal(value["cacheKey"].as_str().unwrap()).await;
            assert_eq!(value["state"], "failed");
            assert_eq!(value["error"], expected);
            assert!(!value.to_string().contains("127.0.0.1"));
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let error = reqwest::Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .get(format!("http://{address}/?signed=secret"))
            .send()
            .await
            .unwrap_err();
        assert_eq!(download_error(error), "media_download_connect");
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(1)).await;
        });
        let error = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_millis(20))
            .build()
            .unwrap()
            .get(format!("http://{address}/?signed=secret"))
            .send()
            .await
            .unwrap_err();
        assert_eq!(download_error(error), "media_download_timeout");
        server.abort();
    }

    #[tokio::test]
    async fn cancelling_terminal_cache_preserves_state_and_failure_error() {
        let f = Fixture::new("wrong_range", 128, ITEM_LIMIT, CACHE_LIMIT).await;
        let value = f.prepare("abcdefghijk", "screen").await;
        let key = value["cacheKey"].as_str().unwrap();
        let failed = f.terminal(key).await;
        assert_eq!(failed["state"], "failed");
        assert_eq!(failed["error"], "media_invalid_range");
        f.media
            .request(
                "media_release",
                json!({"cacheKey":key,"consumerID":"screen"}),
            )
            .await
            .unwrap();
        for state in ["failed", "interrupted", "evicted", "cancelled"] {
            f.media
                .set_state(key, state, Some("media_invalid_range"))
                .await
                .unwrap();
            let result = f
                .media
                .request("media_cancel", json!({"cacheKey":key}))
                .await
                .unwrap();
            assert_eq!(result["state"], state);
            assert_eq!(result["error"], "media_invalid_range");
        }
        let ready = Fixture::new("normal", 128, ITEM_LIMIT, CACHE_LIMIT).await;
        let value = ready.prepare("abcdefghijk", "screen").await;
        let key = value["cacheKey"].as_str().unwrap();
        assert_eq!(ready.terminal(key).await["state"], "ready");
        ready
            .media
            .request(
                "media_release",
                json!({"cacheKey":key,"consumerID":"screen"}),
            )
            .await
            .unwrap();
        assert_eq!(
            ready
                .media
                .request("media_cancel", json!({"cacheKey":key}))
                .await
                .unwrap()["state"],
            "ready"
        );
    }

    #[tokio::test]
    async fn shared_pin_cancel_and_no_duplicate_download() {
        let f = Fixture::new("slow", 2 * 1024 * 1024, ITEM_LIMIT, CACHE_LIMIT).await;
        let value = f.prepare("abcdefghijk", "a").await;
        let key = value["cacheKey"].as_str().unwrap();
        f.prepare("abcdefghijk", "b").await;
        f.media
            .request("media_release", json!({"cacheKey":key,"consumerID":"a"}))
            .await
            .unwrap();
        assert_ne!(
            f.media
                .request("media_cancel", json!({"cacheKey":key}))
                .await
                .unwrap()["state"],
            "cancelled"
        );
        f.media
            .request("media_release", json!({"cacheKey":key,"consumerID":"b"}))
            .await
            .unwrap();
        f.media
            .request("media_cancel", json!({"cacheKey":key}))
            .await
            .unwrap();
        assert_eq!(f.terminal(key).await["state"], "cancelled");
        assert!(f.helper_calls() <= 1);
        assert!(std::fs::read_dir(f.root.join("media-cache"))
            .unwrap()
            .next()
            .is_none());
    }

    #[tokio::test]
    async fn total_quota_never_evicts_playing_pin_then_lru_recovers() {
        let f = Fixture::new("normal", 64, 128, 100).await;
        let a = f.prepare("aaaaaaaaaaa", "a").await;
        assert_eq!(
            f.terminal(a["cacheKey"].as_str().unwrap()).await["state"],
            "ready"
        );
        let b = f.prepare("bbbbbbbbbbb", "b").await;
        assert_eq!(
            f.terminal(b["cacheKey"].as_str().unwrap()).await["error"],
            "media_cache_limit"
        );
        assert_eq!(
            f.media
                .request("media_status", json!({"cacheKey":a["cacheKey"]}))
                .await
                .unwrap()["state"],
            "ready"
        );
        f.media
            .request(
                "media_release",
                json!({"cacheKey":a["cacheKey"],"consumerID":"a"}),
            )
            .await
            .unwrap();
        f.prepare("bbbbbbbbbbb", "b").await;
        assert_eq!(
            f.terminal(b["cacheKey"].as_str().unwrap()).await["state"],
            "ready"
        );
        assert_eq!(
            f.media
                .request("media_status", json!({"cacheKey":a["cacheKey"]}))
                .await
                .unwrap()["state"],
            "evicted"
        );
    }

    #[tokio::test]
    async fn playlist_capability_is_held_until_last_playlist_and_native_owner_release() {
        let f=Fixture::new("normal",64,ITEM_LIMIT,CACHE_LIMIT).await;
        let item=entry(&json!({"pageURL":"https://youtu.be/aaaaaaaaaaa"})).unwrap();
        let saved=item.clone();
        f.media.db.call(move |s| {
            s.connection.execute("INSERT INTO media_cache(cache_key,page_url,height,state,payload,last_used) VALUES(?1,?2,?3,'streaming','{}',0)",params![saved.key,saved.page,saved.height]).map_err(|_|"storage_unavailable")?;
            Ok(())
        }).await.unwrap();
        for native_owners in [vec!["screen-A","screen-B"],vec!["screen-B"]] {
            f.media.set_state(&item.key,"streaming",None).await.unwrap();
            let cap=uuid::Uuid::new_v4().to_string();
            let resource=format!("{cap}/{}",uuid::Uuid::new_v4());
            f.media.playback_sources.lock().await.insert(item.key.clone(),json!({"capability":cap,"descriptor":{"isLive":true}}));
            f.media.live_resources.lock().await.insert(resource.clone(),json!({"_manifest":"#EXTM3U"}));
            {
                let mut state=f.media.state.lock().await;
                state.owners.insert(item.key.clone(),native_owners.iter().map(|s|s.to_string()).collect());
                state.playlist_pins.insert("import-window".into(),HashSet::from([item.key.clone()]));
                state.protected.insert(item.key.clone());
            }
            if native_owners.len()==2 {
                // Stop A and then remove B's native owner: B's imported queue
                // still protects the stream before its replacement prepare.
                for owner in native_owners {
                    f.media.request("media_release",json!({"cacheKey":item.key,"consumerID":owner})).await.unwrap();
                    assert!(f.media.playback_sources.lock().await.contains_key(&item.key));
                    assert!(f.media.live_resources.lock().await.contains_key(&resource));
                    assert_eq!(f.media.status(&item.key).await.unwrap()["state"],"streaming");
                }
                f.media.request("media_playlist_release",json!({"playlistID":"import-window"})).await.unwrap();
            } else {
                // Conversely, closing the queue cannot revoke another actual
                // screen that has already registered its native owner.
                f.media.request("media_playlist_release",json!({"playlistID":"import-window"})).await.unwrap();
                assert!(f.media.playback_sources.lock().await.contains_key(&item.key));
                f.media.request("media_release",json!({"cacheKey":item.key,"consumerID":"screen-B"})).await.unwrap();
            }
            assert!(!f.media.playback_sources.lock().await.contains_key(&item.key));
            assert!(!f.media.live_resources.lock().await.contains_key(&resource));
            assert_eq!(f.media.status(&item.key).await.unwrap()["state"],"cancelled");
        }
    }

    #[tokio::test]
    async fn playlist_release_removes_pins_and_does_not_advance() {
        let f = Fixture::new("normal", 64, ITEM_LIMIT, CACHE_LIMIT).await;
        f.media.request("media_playlist_commit", json!({"playlistID":"release-test","baseRevision":0,
            "items":[{"pageURL":"https://youtu.be/aaaaaaaaaaa"},{"pageURL":"https://youtu.be/bbbbbbbbbbb"}]})).await.unwrap();
        f.media.request("media_playlist_release", json!({"playlistID":"release-test"})).await.unwrap();
        assert!(!f.media.state.lock().await.playlist_pins.contains_key("release-test"));
        let list=f.media.playlist_read("release-test").await.unwrap();
        assert_eq!(list["currentIndex"],0);
        let session="screen-aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa";
        f.media.request("media_playlist_commit",json!({"playlistID":session,"baseRevision":0,"items":[{"pageURL":"https://youtu.be/ccccccccccc"}]})).await.unwrap();
        f.media.request("media_playlist_release",json!({"playlistID":session})).await.unwrap();
        assert_eq!(f.media.playlist_read(session).await.unwrap()["revision"],0);
        assert!(!f.media.state.lock().await.playlist_pins.contains_key(session));
    }

    #[test]
    fn playlist_input_preserves_start_and_bounds_mix() {
        let (url,video,index,limit)=youtube_playlist_input(&json!({"pageURL":"https://www.youtube.com/watch?v=xc7yzjCwH5g&list=RDNrsQHYM9hT4&index=2"})).unwrap();
        assert!(url.contains("list=RDNrsQHYM9hT4"));assert_eq!(video.as_deref(),Some("xc7yzjCwH5g"));assert_eq!(index,1);assert_eq!(limit,50);
        let meta=json!({"entries":[{"id":"aaaaaaaaaaa"},{"id":"xc7yzjCwH5g"},{"id":"bbbbbbbbbbb"}]});
        let (items,start,truncated)=playlist_items(&meta,video.as_deref(),index,2).unwrap();
        assert_eq!(start,1);assert_eq!(items.as_array().unwrap().len(),2);assert!(truncated);
        assert!(youtube_playlist_input(&json!({"pageURL":"https://youtube.com.evil.invalid/playlist?list=PLabc"})).is_err());
        let (_,none,index,limit)=youtube_playlist_input(&json!({"pageURL":"https://youtube.com/playlist?list=PLabc&index=2"})).unwrap();
        assert!(none.is_none());assert_eq!(index,1);assert_eq!(limit,200);
        assert!(playlist_items(&meta,Some("ccccccccccc"),0,2).is_err());
        let unavailable=json!({"entries":[{"id":"aaaaaaaaaaa","availability":"private"},{"id":"bbbbbbbbbbb"},{"id":"ccccccccccc"}]});
        assert_eq!(playlist_items(&unavailable,None,1,3).unwrap().1,0);
    }

    #[tokio::test]
    async fn playlist_import_starts_requested_video_and_releases_ephemeral_session() {
        let f=Fixture::new("playlist",64,ITEM_LIMIT,CACHE_LIMIT).await;
        let id="screen-bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb";
        let list=f.media.request("media_playlist_import",json!({"playlistID":id,"baseRevision":0,"pageURL":"https://www.youtube.com/watch?v=bbbbbbbbbbb&list=PLfixture&index=2"})).await.unwrap();
        assert_eq!(list["currentIndex"],1);assert_eq!(list["items"].as_array().unwrap().len(),3);assert_eq!(list["truncated"],false);
        assert_eq!(f.media.status(list["items"][0]["cacheKey"].as_str().unwrap()).await.unwrap()["state"],"missing");
        for item in list["items"].as_array().unwrap().iter().skip(1) {assert_eq!(f.terminal(item["cacheKey"].as_str().unwrap()).await["state"],"ready");}
        let next=f.media.request("media_playlist_advance",json!({"playlistID":id,"baseRevision":1})).await.unwrap();
        assert_eq!(next["currentIndex"],2);assert_eq!(next["revision"],2);
        assert_eq!(f.media.request("media_playlist_advance",json!({"playlistID":id,"baseRevision":1,"index":2})).await.unwrap_err(),"media_revision_conflict");
        f.media.request("media_playlist_release",json!({"playlistID":id})).await.unwrap();
        assert_eq!(f.media.playlist_read(id).await.unwrap()["items"],json!([]));
        assert!(f.media.state.lock().await.protected.is_empty());
    }

    #[tokio::test]
    async fn playlist_is_durable_prefetches_only_next_and_cas_wins_once() {
        let f = Fixture::new("normal", 64, ITEM_LIMIT, CACHE_LIMIT).await;
        let input = json!({"playlistID":"main","baseRevision":0,"currentIndex":0,"items":[
            {"pageURL":"https://youtu.be/aaaaaaaaaaa","maxHeight":2160},
            {"pageURL":"https://youtu.be/bbbbbbbbbbb","maxHeight":2160},
            {"pageURL":"https://youtu.be/ccccccccccc","maxHeight":2160}]});
        let list = f
            .media
            .request("media_playlist_commit", input.clone())
            .await
            .unwrap();
        assert_eq!(list["revision"], 1);
        assert_eq!(
            f.media
                .request("media_playlist_commit", input)
                .await
                .unwrap_err(),
            "media_revision_conflict"
        );
        for item in list["items"].as_array().unwrap().iter().take(2) {
            assert_eq!(
                f.terminal(item["cacheKey"].as_str().unwrap()).await["state"],
                "ready"
            );
        }
        assert_eq!(f.helper_calls(), 2);
        let last = &list["items"][2]["cacheKey"];
        assert_eq!(
            f.media
                .request("media_status", json!({"cacheKey":last}))
                .await
                .unwrap()["state"],
            "missing"
        );
        let advanced = f
            .media
            .request(
                "media_playlist_advance",
                json!({"playlistID":"main","baseRevision":1}),
            )
            .await
            .unwrap();
        assert_eq!(advanced["revision"], 2);
        assert_eq!(advanced["currentIndex"], 1);
        assert_eq!(f.terminal(last.as_str().unwrap()).await["state"], "ready");
        let restarted = Media::new(Database::open(f.root.clone(), None).unwrap());
        restarted.initialize(None).await.unwrap();
        let read = restarted
            .request("media_playlist_read", json!({"playlistID":"main"}))
            .await
            .unwrap();
        assert_eq!(read["revision"], 2);
        assert_eq!(read["currentIndex"], 1);
        assert_eq!(read["current"]["state"], "ready");
    }

    #[test]
    fn canonical_identity_and_policy_do_not_persist_signed_or_tracking_urls() {
        let a = entry(&json!({"pageURL":"https://youtu.be/abcdefghijk?si=tracking"})).unwrap();
        let b=entry(&json!({"pageURL":"https://www.youtube.com/watch?v=abcdefghijk&expire=1&signature=secret"})).unwrap();
        assert_eq!(a.key, b.key);
        assert_eq!(a.height, 2160);
        assert_ne!(
            a.key,
            entry(&json!({"pageURL":a.page,"maxHeight":1080}))
                .unwrap()
                .key
        );
        assert!(entry(
            &json!({"pageURL":"https://user:secret@www.youtube.com/watch?v=abcdefghijk"})
        )
        .is_err());
        let live = json!({"is_live":true});
        assert_eq!(streams(&live, 2160).unwrap_err(), "media_live_unsupported");
        let drm = json!({"has_drm":true});
        assert_eq!(streams(&drm, 2160).unwrap_err(), "media_restricted");
        let wrong = json!({"vcodec":"av01","acodec":"mp4a","height":2160});
        assert_eq!(
            streams(&wrong, 2160).unwrap_err(),
            "media_unsupported_format"
        );
    }

    #[tokio::test]
    async fn recovery_cleans_orphan_final_and_partial_but_keeps_ready() {
        let f = Fixture::new("normal", 64, ITEM_LIMIT, CACHE_LIMIT).await;
        let prepared = f.prepare("abcdefghijk", "screen").await;
        let key = prepared["cacheKey"].as_str().unwrap();
        assert_eq!(f.terminal(key).await["state"], "ready");
        let orphan = entry(&json!({"pageURL":"https://youtu.be/aaaaaaaaaaa"})).unwrap();
        let path = f
            .root
            .join("media-cache")
            .join(format!("{}.video.mp4", orphan.key));
        std::fs::write(&path, &f.bytes).unwrap();
        let part = f.root.join("media-cache").join(format!("{key}.video.part"));
        std::fs::write(&part, &f.bytes).unwrap();
        let restarted = Media::new(Database::open(f.root.clone(), None).unwrap());
        restarted.initialize(None).await.unwrap();
        assert!(!path.exists());
        assert!(!part.exists());
        assert_eq!(
            restarted
                .request("media_status", json!({"cacheKey":key}))
                .await
                .unwrap()["state"],
            "ready"
        );
        let descriptor = restarted
            .request("media_status", json!({"cacheKey":key}))
            .await
            .unwrap()["descriptor"]
            .clone();
        let ready_path = reqwest::Url::parse(descriptor["video"]["url"].as_str().unwrap())
            .unwrap()
            .to_file_path()
            .unwrap();
        let mut damaged = f.bytes.clone();
        damaged[30] ^= 1;
        std::fs::write(ready_path, damaged).unwrap();
        let cold = Media::new(Database::open(f.root.clone(), None).unwrap());
        cold.initialize(None).await.unwrap();
        assert_eq!(
            cold.request("media_status", json!({"cacheKey":key}))
                .await
                .unwrap()["state"],
            "interrupted"
        );
    }

    #[tokio::test]
    async fn committed_playlist_reports_prefetch_failure_without_false_cas_failure() {
        let f = Fixture::new("normal", 64, ITEM_LIMIT, CACHE_LIMIT).await;
        // Simulate a full persisted scheduler boundary without launching 64
        // network workers; the actual commit and readback still use SQLite.
        {
            let mut s = f.media.state.lock().await;
            s.known.extend((0..64).map(|n| format!("pending-{n}")));
        }
        let result=f.media.request("media_playlist_commit",json!({"playlistID":"full","baseRevision":0,"items":[{"pageURL":"https://youtu.be/abcdefghijk"}]})).await.unwrap();
        assert_eq!(result["revision"], 1);
        assert_eq!(result["prefetchError"], "media_queue_full");
        let read = f
            .media
            .request("media_playlist_read", json!({"playlistID":"full"}))
            .await
            .unwrap();
        assert_eq!(read["revision"], 1);
        assert_eq!(read["items"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn redirected_sources_keep_the_public_https_host_policy() {
        let cdn = reqwest::Url::parse("https://rr1.googlevideo.com/media").unwrap();
        assert!(redirect_allowed(&cdn, 1));
        assert!(redirect_allowed(&cdn, 2));
        assert!(!redirect_allowed(&cdn, 3));
        assert!(!redirect_allowed(&cdn, 4));
        for url in [
            "https://rr1.googlevideo.com/videoplayback",
            "https://googlevideo.com/videoplayback",
            "https://cdn.bilivideo.cn/media",
        ] {
            assert!(public_source_url(&reqwest::Url::parse(url).unwrap()));
        }
        for url in [
            "http://rr1.googlevideo.com/videoplayback",
            "https://googlevideo.com.attacker.invalid/media",
            "https://notgooglevideo.com/media",
            "https://127.0.0.1/media",
            "https://localhost/media",
            "https://user:password@rr1.googlevideo.com/media",
            "https://rr1.googlevideo.com:8443/media",
        ] {
            assert!(!public_source_url(&reqwest::Url::parse(url).unwrap()));
        }
    }

    #[tokio::test]
    #[ignore = "opt-in public network probe; requires GMGN_MEDIA_PROBE_HELPERS"]
    async fn configured_system_proxy_fetches_public_cdn_ranges() {
        let directory =
            PathBuf::from(std::env::var("GMGN_MEDIA_PROBE_HELPERS").expect("helper directory"));
        let helpers = Helpers {
            helper: directory.join("yt-dlp"),
            helper_sha256: std::fs::read_to_string(directory.join("yt-dlp.sha256"))
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap()
                .to_owned(),
            deno: directory.join("deno"),
            deno_sha256: std::fs::read_to_string(directory.join("deno.sha256"))
                .unwrap()
                .split_whitespace()
                .next()
                .unwrap()
                .to_owned(),
        };
        let video_id =
            std::env::var("GMGN_MEDIA_PROBE_VIDEO_ID").unwrap_or_else(|_| "h8RwpmEyvRY".into());
        let item =
            entry(&json!({"pageURL":youtube_page(&video_id).unwrap(),"maxHeight":2160})).unwrap();
        let info = resolve(&item, &helpers).await.unwrap();
        let (video, audio) = streams(&info, 2160).unwrap();
        let client = download_client_builder().build().unwrap();
        // No cache or database is involved. Read only the requested 1 KiB,
        // never reqwest's URL-bearing error Display or the signed URLs.
        for (kind, stream) in [("video", video), ("audio", audio.expect("AAC audio"))] {
            let url = reqwest::Url::parse(stream["url"].as_str().unwrap()).unwrap();
            assert!(public_source_url(&url));
            let mut request = client
                .get(url)
                .header(reqwest::header::RANGE, "bytes=0-1023");
            if let Some(headers) = stream["http_headers"].as_object() {
                for (name, value) in headers {
                    if [
                        "user-agent",
                        "referer",
                        "accept",
                        "accept-language",
                        "origin",
                    ]
                    .contains(&name.to_ascii_lowercase().as_str())
                    {
                        request = request.header(name, value.as_str().unwrap());
                    }
                }
            }
            let mut exhausted = false;
            let mut response =
                retry_connect_eof(|| request.try_clone().unwrap().send(), &mut exhausted)
                    .await
                    .unwrap();
            assert_eq!(response.status(), reqwest::StatusCode::PARTIAL_CONTENT);
            let range = response.headers()[reqwest::header::CONTENT_RANGE]
                .to_str()
                .unwrap();
            let (start, end, _) = content_range(range).unwrap();
            assert_eq!((start, end), (0, 1023));
            let mut bytes = 0;
            while bytes < 1024 {
                let chunk = response
                    .chunk()
                    .await
                    .map_err(download_error)
                    .unwrap()
                    .expect("range body");
                bytes += chunk.len();
                assert!(bytes <= 1024);
            }
            println!("public CDN {kind}: system route HTTP 206, {bytes} bytes");
        }
    }

    #[test]
    fn oldest_background_gets_a_turn_under_continuous_new_current_and_next() {
        let mut state = State::default();
        let old = Entry {
            key: "old-next".into(),
            page: "fixture".into(),
            height: 2160,
        };
        state.queue.push_back(old.clone());
        state.enqueued.insert(old.key.clone(), 0);
        let mut selected = None;
        for n in 1..=5 {
            let current = Entry {
                key: format!("current-{n}"),
                page: "fixture".into(),
                height: 2160,
            };
            let next = Entry {
                key: format!("next-{n}"),
                page: "fixture".into(),
                height: 2160,
            };
            state.enqueued.insert(current.key.clone(), n * 2 - 1);
            state.queue.push_front(current);
            state.enqueued.insert(next.key.clone(), n * 2);
            state.queue.push_back(next);
            if state.next().unwrap().key == "old-next" {
                selected = Some(n);
                break;
            }
        }
        assert_eq!(selected, Some(5));
    }

    #[tokio::test]
    async fn helper_integrity_and_html_never_create_ready_media() {
        let f = Fixture::new("html", 64, ITEM_LIMIT, CACHE_LIMIT).await;
        let item = f.prepare("abcdefghijk", "screen").await;
        assert_eq!(
            f.terminal(item["cacheKey"].as_str().unwrap()).await["error"],
            "media_invalid_content"
        );
        let mut wrong = f.helpers.clone();
        wrong.helper_sha256 = "0".repeat(64);
        let fresh = Media::new(Database::open(f.root.clone(), None).unwrap());
        assert_eq!(
            fresh.initialize(Some(wrong)).await.unwrap_err(),
            "media_helper_integrity_failed"
        );
    }

    #[tokio::test]
    async fn concurrent_old_hash_checks_cannot_remove_a_fresh_ready_generation() {
        let f = Fixture::new("normal", 2 * 1024 * 1024, ITEM_LIMIT, CACHE_LIMIT).await;
        let queued = f.prepare("abcdefghijk", "original").await;
        let key = queued["cacheKey"].as_str().unwrap().to_owned();
        let ready = f.terminal(&key).await;
        let path = reqwest::Url::parse(ready["descriptor"]["video"]["url"].as_str().unwrap())
            .unwrap()
            .to_file_path()
            .unwrap();
        let mut bad = f.bytes.clone();
        bad[30] ^= 1;
        std::fs::write(path, bad).unwrap();
        let mut checks = Vec::new();
        for n in 0..12 {
            let media = f.media.clone();
            let key = key.clone();
            checks.push(tokio::spawn(async move {
                if n%2==0 {media.request("media_status",json!({"cacheKey":key})).await}
                else {media.request("media_prepare",json!({"pageURL":"https://youtu.be/abcdefghijk","consumerID":format!("consumer-{n}")})).await}
            }));
        }
        for check in checks {
            check.await.unwrap().unwrap();
        }
        assert_eq!(f.terminal(&key).await["state"], "ready");
        assert_eq!(
            f.media
                .request("media_status", json!({"cacheKey":key}))
                .await
                .unwrap()["state"],
            "ready"
        );
        assert_eq!(f.helper_calls(), 2);
    }
}
