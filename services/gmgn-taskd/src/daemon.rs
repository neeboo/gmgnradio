use crate::{
    contract, files, memory, messages, music,
    model::{self, Result, Stored, Submit, FRAME_LIMIT},
    provider, resident,
    store::Database,
    world,
};
use gmgn_protocol::Request;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{
    sync::RwLock,
    task::JoinSet,
};

#[derive(Clone)]
pub struct Service {
    pub db: Database,
    pub media: Arc<crate::media::Media>,
    credentials: Arc<RwLock<HashMap<String, String>>>,
    memory: Arc<memory::Memory>,
    /// The generation backend this daemon is bound to. Scheduling, cancellation
    /// bookkeeping, integrity checks and local storage stay here; the backend
    /// owns only the remote calls behind [`provider::PropProvider`].
    provider: Arc<dyn provider::PropProvider>,
    agent_runtime: Arc<crate::agent_runtime::RuntimeService>,
    agent_cli: Arc<crate::agent_cli::CliService>,
    agent_dsh: Arc<crate::agent_dsh::DshService>,
    agent_claude: Arc<crate::agent_claude::ClaudeService>,
    agent_chat: Arc<crate::agent_chat::ChatService>,
    music_dj: Arc<crate::music_program::ProgramService>,
    screen_playback: Arc<crate::screen_playback::ScreenPlaybackService>,
    screen_state: Arc<crate::screen_state::ScreenStateService>,
    pub(crate) speech_delivery: Arc<crate::speech_delivery::SpeechDeliveryService>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MessageScope {
    consumer: String,
    #[serde(rename = "worldID")]
    world_id: String,
    resident_scope: String,
}

impl Service {
    pub fn new(db: Database) -> Result<Self> {
        Self::with_provider(
            db,
            Arc::new(provider::RemoteHTTPProvider::new(provider::client()?)),
        )
    }

    /// Binds the daemon to an explicit backend. Tests use it to drive the same
    /// scheduler and HTTP surface without an external network.
    pub fn with_provider(db: Database, provider: Arc<dyn provider::PropProvider>) -> Result<Self> {
        let media = crate::media::Media::new(db.clone());
        Ok(Self {
            agent_runtime: Arc::new(crate::agent_runtime::RuntimeService::new(db.clone())),
            agent_cli: Arc::new(crate::agent_cli::CliService::new(db.clone())),
            agent_dsh: Arc::new(crate::agent_dsh::DshService::new(db.clone())),
            agent_claude: Arc::new(crate::agent_claude::ClaudeService::new(db.clone())),
            agent_chat: Arc::new(crate::agent_chat::ChatService::new(db.clone())),
            music_dj: Arc::new(crate::music_program::ProgramService::new(db.clone())),
            screen_playback: Arc::new(crate::screen_playback::ScreenPlaybackService::new(db.clone(), media.clone())),
            screen_state: Arc::new(crate::screen_state::ScreenStateService::new(db.clone())),
            speech_delivery: Arc::new(crate::speech_delivery::SpeechDeliveryService::new(db.clone())),
            db: db.clone(),
            media,
            credentials: Arc::new(RwLock::new(HashMap::new())),
            memory: Arc::new(memory::Memory::new(db)),
            provider,
        })
    }

    /// Credential hygiene for the additive memory methods (contract §1): any
    /// configured wish origin token appearing anywhere in the params rejects
    /// the whole request. Long-term memory owns no credential of its own since
    /// the external VoiceMem provider layer was removed.
    async fn has_configured_secret(&self, params: &Value) -> bool {
        let tokens: Vec<String> = self.credentials.read().await.values().cloned().collect();
        tokens
            .iter()
            .any(|token| provider::contains_secret(params, token))
    }
    pub(crate) async fn accepts_dsh_grant(&self, token: &str) -> bool {
        self.agent_dsh.accepts_grant(token).await
    }
    pub(crate) async fn dsh_host_call(&self, token: &str, params: &Value) -> Result<Value> {
        self.agent_dsh.host_call(token, params).await
    }
    pub(crate) async fn accepts_claude_grant(&self, token: &str) -> bool {
        self.agent_claude.accepts_grant(token).await
    }
    pub(crate) async fn claude_host_call(&self, token: &str, params: &Value) -> Result<Value> {
        self.agent_claude.host_call(token, params).await
    }
    pub(crate) async fn request(&self, method: &str, params: Value) -> Result<Value> {
        match method {
            "screen_state_read" | "screen_state_mutate" | "screen_state_import" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                self.screen_state.request(method, &params).await
            }
            "speech_delivery_enqueue" | "speech_delivery_read" | "speech_delivery_wait"
            | "speech_delivery_receipt" | "speech_delivery_cancel" | "chat_speech_event" | "chat_speech_read" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                self.speech_delivery.request(method, params).await
            }
            "agent_chat_start" | "agent_chat_read" | "agent_chat_cancel"
            | "agent_chat_reset" | "agent_chat_import" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                self.agent_chat.request(method, &params).await
            }
            "agent_claude_start" | "agent_claude_read" | "agent_claude_authorize"
            | "agent_claude_tool_receipt" | "agent_claude_cancel" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                self.agent_claude.request(method, &params).await
            }
            "screen_playback_begin" | "screen_playback_read" | "screen_playback_receipt"
            | "screen_playback_stop" | "screen_playback_attach" | "screen_playback_resume" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                self.screen_playback.request(method, &params).await
            }
            "agent_dsh_start" | "agent_dsh_read" | "agent_dsh_authorize"
            | "agent_dsh_tool_receipt" | "agent_dsh_cancel" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                self.agent_dsh.request(method, &params).await
            }
            "resident_intent_restore" | "resident_intent_update" | "resident_intent_pause"
            | "resident_intent_enqueue" | "resident_intent_drain" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    crate::resident_intent::request(&mut s.connection, &method, &params)
                }).await
            }
            "world_control_bind_catalog" | "world_control_ui_intent" | "world_control_command" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                let method = method.to_owned();
                self.db.call(move |s| crate::world_control::request(&mut s.connection, &method, &params)).await
            }
            "inbox_control_read" | "inbox_control_deliver" | "inbox_control_post"
            | "inbox_control_mark_read" | "inbox_control_import" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                let method = method.to_owned();
                self.db.call(move |s| crate::inbox_control::request(&mut s.connection, &method, &params)).await
            }
            "stage_video_read" | "stage_video_import" | "stage_video_command" | "stage_video_receipt" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                let method = method.to_owned();
                self.db.call(move |s| crate::stage_video::request(&s.connection, &method, &params)).await
            }
            "marble_control_read" | "marble_control_command" | "marble_control_action_claim"
            | "marble_control_action_receipt" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                let method = method.to_owned();
                let root = self.db.root.clone();
                self.db.call(move |s| crate::marble_control::request(&mut s.connection, &root, &method, params)).await
            }
            "marble_geometry_sample_plan" => {
                let count = params["pointCount"].as_u64().and_then(|v| usize::try_from(v).ok())
                    .ok_or("marble_geometry_invalid_input")?;
                tokio::task::spawn_blocking(move || crate::marble_geometry::sample_plan(count))
                    .await.map_err(|_| "marble_geometry_unavailable")?
            }
            "marble_geometry_plan" | "marble_geometry_resolve" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                let mut refs = HashSet::new();
                for field in [&params["geometry"]["triangleChunks"], &params["measurementChunks"]] {
                    if field.is_null() { continue; }
                    for value in field.as_array().ok_or("marble_geometry_invalid_input")? {
                        let sha = value.as_str().filter(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
                            .ok_or("marble_geometry_invalid_input")?;
                        refs.insert(sha.to_owned());
                    }
                }
                if refs.len() > 4096 { return Err("marble_geometry_invalid_input"); }
                // Only metadata lookup runs on the storage executor. File IO,
                // hashing and geometry calculation stay off that executor.
                let descriptors = self.db.call(move |s| {
                    let mut descriptors = HashMap::new();
                    for sha in refs {
                        let (bytes, path): (i64, Option<String>) = s.connection.query_row(
                            "SELECT bytes, local_path FROM world_blobs WHERE sha256=?1",
                            [&sha], |row| Ok((row.get(0)?, row.get(1)?)),
                        ).map_err(|_| "marble_geometry_invalid_proof")?;
                        let path = path.ok_or("marble_geometry_invalid_proof")?;
                        if !(0..=4 * 1024 * 1024).contains(&bytes) { return Err("marble_geometry_invalid_proof"); }
                        descriptors.insert(sha, (bytes as u64, PathBuf::from(path)));
                    }
                    Ok(descriptors)
                }).await?;
                let root = self.db.root.clone();
                let method = method.to_owned();
                tokio::task::spawn_blocking(move || {
                    use std::io::Read;
                    let root = root.canonicalize().map_err(|_| "marble_geometry_invalid_proof")?;
                    let mut load = |sha: &str| {
                        let (expected, path) = descriptors.get(sha).ok_or("marble_geometry_invalid_proof")?;
                        let path = path.canonicalize().map_err(|_| "marble_geometry_invalid_proof")?;
                        if !path.starts_with(&root) { return Err("marble_geometry_invalid_proof"); }
                        let file = std::fs::File::open(path).map_err(|_| "marble_geometry_invalid_proof")?;
                        let metadata = file.metadata().map_err(|_| "marble_geometry_invalid_proof")?;
                        if !metadata.is_file() || metadata.len() != *expected { return Err("marble_geometry_invalid_proof"); }
                        let mut bytes = Vec::new();
                        file.take(4 * 1024 * 1024 + 1).read_to_end(&mut bytes).map_err(|_| "marble_geometry_invalid_proof")?;
                        if bytes.len() as u64 != *expected { return Err("marble_geometry_invalid_proof"); }
                        Ok(bytes)
                    };
                    if method == "marble_geometry_plan" {
                        crate::marble_geometry::plan_page(&params, &mut load)
                    } else {
                        crate::marble_geometry::resolve_chunks(&params, &mut load)
                    }
                })
                    .await.map_err(|_| "marble_geometry_unavailable")?
            }
            "world_prop_capability_plan" | "world_prop_capability_resolve" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                let method = method.to_owned();
                self.db.call(move |s| crate::world_prop_capability::request(&s.connection, &method, params)).await
            }
            "world_activity_approach_plan" | "world_activity_approach_resolve" | "world_activity_approach_places" => {
                if self.has_configured_secret(&params).await { return Err("secret_in_input"); }
                let method = method.to_owned();
                self.db.call(move |s| crate::world_activity_approach::request(&s.connection, &method, params)).await
            }
            "world_device_catalog_install" | "world_device_ui_intent" | "world_device_preview"
            | "world_device_command" | "world_device_refresh" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    let root = s.root.clone();
                    let tx = s.connection.transaction().map_err(|_| "storage_unavailable")?;
                    let result = crate::world_device::request(&tx, &root, &method, params)?;
                    tx.commit().map_err(|_| "storage_unavailable")?;
                    Ok(result)
                }).await
            }
            "world_prop_read" | "world_prop_observe" | "world_prop_ui_intent"
            | "world_prop_surfaces" | "world_prop_preview" | "world_prop_command"
            | "world_prop_register" | "world_prop_rebase" | "world_prop_receipt"
            | "world_prop_system_avatar_return" | "world_prop_output_preview" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    let root = s.root.clone();
                    let tx = s.connection.transaction().map_err(|_| "storage_unavailable")?;
                    let result = crate::world_prop::request(&tx, &root, &method, params)?;
                    tx.commit().map_err(|_| "storage_unavailable")?;
                    Ok(result)
                }).await
            }
            "world_activity_read" | "world_activity_bind_catalog" | "world_activity_start"
            | "world_activity_receipt" | "world_activity_stop" | "world_activity_continue"
            | "world_activity_move" | "world_activity_replan" | "world_activity_prepare" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    let tx = s.connection.transaction().map_err(|_| "storage_unavailable")?;
                    let result = crate::world_activity::request(&tx, &method, params)?;
                    tx.commit().map_err(|_| "storage_unavailable")?;
                    Ok(result)
                }).await
            }
            "wish_control_open" | "wish_control_read" | "wish_control_commit"
            | "wish_control_claim" | "wish_control_pause" | "wish_control_resume"
            | "wish_control_event_ack" | "wish_control_discard_unproven_pauses"
            | "wish_control_retry_authorize" | "wish_control_command" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    crate::wish_control::request(&mut s.connection, &method, &params)
                }).await
            }
            "agent_cli_start" | "agent_cli_read" | "agent_cli_authorize"
            | "agent_cli_tool_receipt" | "agent_cli_cancel" | "agent_cli_reset" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                self.agent_cli.request(method, &params).await
            }
            "music_knowledge_read" | "music_knowledge_ingest" | "music_knowledge_event" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| crate::music_knowledge::request(&mut s.connection, &method, &params)).await
            }
            "music_program_playback_command" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                self.db.call(move |s| crate::music_playback::program_request(&mut s.connection, params)).await
            }
            "music_playback_read" | "music_playback_begin" | "music_playback_navigate"
            | "music_playback_commit" | "music_playback_receipt" | "music_playback_clear"
            | "music_playback_replace_upcoming" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    crate::music_playback::request(&mut s.connection, &method, params)
                }).await
            }
            "agent_runtime_configure" | "agent_runtime_start" | "agent_runtime_read"
            | "agent_runtime_cancel" | "agent_runtime_tool_receipt" | "agent_runtime_reconcile"
            | "agent_runtime_authorize" | "agent_runtime_steer" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                self.agent_runtime.request(method, &params).await
                    .map_err(|error| crate::agent_runtime::public_error_code(&error))
            }
            "agent_tool_begin" | "agent_tool_finish" | "agent_tool_inspect" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    crate::agent_tools::request(&mut s.connection, &method, &params)
                }).await
            }
            "world_activity_route" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                crate::world_activity::route(&params)
            }
            "activity_catalog_build" | "activity_manifest_build" | "activity_seat_definition" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                crate::activity::request(method, params)
            }
            "agent_loop_configure" | "agent_loop_enqueue" | "agent_loop_claim"
            | "agent_loop_complete" | "agent_loop_cancel" | "agent_loop_read"
            | "agent_loop_confirm_cancel" | "agent_loop_reconcile"
            | "agent_loop_steer_admit" | "agent_loop_steer_finish" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    crate::agent_scheduler::request(&mut s.connection, &method, &params)
                }).await
            }
            "media_prepare" | "media_status" | "media_cancel" | "media_release"
            | "media_playlist_commit" | "media_playlist_read" | "media_playlist_advance"
            | "media_playlist_import" | "media_playlist_release" => {
                if self.has_configured_secret(&params).await {return Err("secret_in_input");}
                self.media.request(method, params).await
            }
            "wish_reference_search" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                crate::wish_reference::search(self.db.clone(), params).await
            }
            "wish_reference_prepare" | "wish_reference_complete" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| crate::wish_reference::request(&mut s.connection, &method, &params)).await
            }
            "chat_attachments_open" | "chat_attachments_read" | "chat_attachments_register"
            | "chat_attachments_remove" | "chat_attachments_take" | "chat_attachments_restore"
            | "chat_attachments_finish" | "chat_attachments_close" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| crate::chat_attachments::request(&mut s.connection, &method, &params)).await
            }
            "presence_selection_bind_catalog" | "presence_selection_read" | "presence_selection_event"
            | "presence_selection_remove_intent" | "presence_selection_remove_claim" | "presence_selection_remove_receipt" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| crate::presence_selection::request(&mut s.connection, &method, &params)).await
            }
            "music_dj_plan" => self.music_dj.plan(params).await,
            "music_dj_discovery" | "music_dj_read" | "music_dj_command"
            | "music_dj_playlist_plan" | "music_dj_candidates" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| crate::music_program::request(&mut s.connection, &method, params)).await
            }
            "product_settings_read" | "product_settings_import" | "product_settings_apply"
            | "product_settings_stage_event" | "product_settings_stage_import"
            | "product_settings_bind_catalog" | "product_settings_shortcut_event"
            | "product_settings_music_receipt" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| crate::product_settings::request(&mut s.connection, &method, &params)).await
            }
            "jukebox_begin" | "jukebox_read" | "jukebox_claim" | "jukebox_receipt" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| {
                    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
                        .map_err(|_| "jukebox_invalid_state")?.as_millis().min(u64::MAX as u128) as u64;
                    let tx = s.connection.transaction().map_err(|_| "storage_unavailable")?;
                    let result = crate::jukebox::request(&tx, &method, &params, now)?;
                    tx.commit().map_err(|_| "storage_unavailable")?;
                    Ok(result)
                }).await
            }
            "music_cache_prepare" | "music_cache_read" | "music_cache_claim" | "music_cache_receipt" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                crate::music_cache::request(&self.db, &method, params).await
            }
            // Music-account authority. `connect` is the one arm that owns the
            // provider round-trip itself (`music_account_http`); every other
            // method is a pure storage decision.
            "music_account_session_state" | "music_account_session" | "music_account_import"
            | "music_account_disconnect" | "music_account_apple_authorization" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                let root = self.db.root.clone();
                self.db.call(move |s| {
                    crate::music_account::request(&mut s.connection, &root, &method, &params)
                }).await
            }
            "music_account_connect" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                crate::music_account::connect(&self.db, params).await
            }
            "generation_configuration_read" | "generation_configuration_save"
            | "generation_configuration_import" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                let root = self.db.root.clone();
                self.db.call(move |s| {
                    crate::generation_configuration::dispatch(&mut s.connection, &root, &method, &params)
                }).await
            }
            "music_program_save" | "music_library_commit" => {
                Err("invalid_music_input")
            }
            "music_library_edit" | "music_library_page_begin" | "music_library_page_end" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| crate::music_library::request(&mut s.connection, &method, params)).await
            }
            "music_program_list" | "music_library_read"
            | "music_import" => {
                if self.has_configured_secret(&params).await {
                    return Err("secret_in_input");
                }
                let method = method.to_owned();
                self.db.call(move |s| music::request(&mut s.connection, &method, params)).await
            }
            "configure" => {
                let origin =
                    model::endpoint(params["endpoint"].as_str().ok_or("invalid_endpoint")?)?;
                let token = params["token"].as_str().ok_or("invalid_token")?;
                if token.is_empty()
                    || token.len() > 8192
                    || !token.bytes().all(|b| (33..=126).contains(&b))
                {
                    return Err("invalid_token");
                }
                self.credentials
                    .write()
                    .await
                    .insert(origin, token.to_owned());
                Ok(json!({"configured":true}))
            }
            "snapshot" => {
                let cursor = if params["cursor"].is_null() {
                    None
                } else {
                    Some(
                        params["cursor"]
                            .as_str()
                            .ok_or("invalid_cursor")?
                            .to_owned(),
                    )
                };
                self.db.call(move |s| s.snapshot(cursor)).await
            }
            "submit" => {
                let input: Submit = serde_json::from_value(params).map_err(|_| "invalid_input")?;
                self.db
                    .call(move |s| Ok(json!({"job":s.submit(input)?})))
                    .await
            }
            "cancel" | "retry" => {
                let id = model::identity(params["id"].as_str().ok_or("invalid_id")?)?;
                let cancel = method == "cancel";
                self.db
                    .call(move |s| {
                        Ok(json!({"job":if cancel { s.cancel(&id)? } else { s.retry(&id)? }}))
                    })
                    .await
            }
            "failover" => {
                let id = model::identity(params["id"].as_str().ok_or("invalid_id")?)?;
                let endpoint = params["endpoint"]
                    .as_str()
                    .ok_or("invalid_endpoint")?
                    .to_owned();
                let profile: Option<model::GenerationProfile> =
                    match params.get("generationProfile") {
                        None | Some(Value::Null) => None,
                        Some(value) => Some(
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid_generation_profile")?,
                        ),
                    };
                self.db
                    .call(move |s| {
                        let (job, replaced) = s.failover(&id, &endpoint, profile)?;
                        Ok(json!({"job": job, "replaced": replaced}))
                    })
                    .await
            }
            "providers_status" => {
                // Read-only and offline: it describes the backend this daemon is
                // bound to plus every origin that has a credential or a job. No
                // token ever appears in the reply.
                let mut endpoints: BTreeMap<String, (bool, u64, u64)> = BTreeMap::new();
                for endpoint in self.credentials.read().await.keys() {
                    endpoints.entry(endpoint.clone()).or_insert((true, 0, 0)).0 = true;
                }
                for value in self.db.call(|s| s.all()).await? {
                    let row = endpoints
                        .entry(value.job.endpoint.clone())
                        .or_insert((false, 0, 0));
                    row.1 += 1;
                    if model::is_active(&value.job) {
                        row.2 += 1;
                    }
                }
                let endpoints: Vec<Value> = endpoints
                    .into_iter()
                    .map(|(endpoint, (configured, jobs, active))| {
                        json!({"endpoint":endpoint,"configured":configured,"jobs":jobs,"activeJobs":active})
                    })
                    .collect();
                Ok(json!({"provider": self.provider.capabilities(), "endpoints": endpoints}))
            }
            "provider_probe" => {
                let endpoint =
                    model::endpoint(params["endpoint"].as_str().ok_or("invalid_endpoint")?)?;
                let input_px = match params.get("inputPx") {
                    None | Some(Value::Null) => None,
                    Some(value) => Some(
                        value
                            .as_u64()
                            .filter(|n| (1..=16384).contains(n))
                            .ok_or("invalid_input_px")? as u32,
                    ),
                };
                let token = self.credentials.read().await.get(&endpoint).cloned();
                let capabilities = self.provider.probe(&endpoint, token.as_deref()).await?;
                let ready = capabilities.is_ready();
                let accepts_input_px = input_px.map(|px| capabilities.accepts_input_px(px));
                Ok(
                    json!({"endpoint":endpoint,"ready":ready,"acceptsInputPx":accepts_input_px,"capabilities":capabilities}),
                )
            }
            "publish_message" => {
                if self
                    .credentials
                    .read()
                    .await
                    .values()
                    .any(|token| provider::contains_secret(&params, token))
                {
                    return Err("invalid_message");
                }
                let message: messages::NewMessage =
                    serde_json::from_value(params).map_err(|_| "invalid_message")?;
                self.db
                    .call(move |s| {
                        let tx = s
                            .connection
                            .transaction()
                            .map_err(|_| "storage_unavailable")?;
                        let result = messages::publish(&tx, &message).map_err(|e| e.code)?;
                        tx.commit().map_err(|_| "storage_unavailable")?;
                        s.changed.send_modify(|v| *v = v.wrapping_add(1));
                        Ok(json!({"message":result}))
                    })
                    .await
            }
            "ack_message" => {
                let id = params["id"]
                    .as_str()
                    .ok_or("invalid_message_id")?
                    .to_owned();
                let scope: MessageScope =
                    serde_json::from_value(params).map_err(|_| "invalid_message_scope")?;
                self.db
                    .call(move |s| {
                        let tx = s
                            .connection
                            .transaction()
                            .map_err(|_| "storage_unavailable")?;
                        messages::ack(
                            &tx,
                            &id,
                            &scope.consumer,
                            &scope.world_id,
                            &scope.resident_scope,
                        )
                        .map_err(|e| e.code)?;
                        tx.commit().map_err(|_| "storage_unavailable")?;
                        Ok(json!({"acknowledged":true}))
                    })
                    .await
            }
            "state_read" => {
                let request: resident::StateReadRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_state_read")?;
                self.db
                    .call(move |s| {
                        let record = resident::read_state(
                            &s.connection,
                            &request.scope,
                            &request.domain,
                            &request.key,
                        )
                        .map_err(|e| e.code)?;
                        Ok(json!({"record": record}))
                    })
                    .await
            }
            "state_commit" => {
                if self
                    .credentials
                    .read()
                    .await
                    .values()
                    .any(|token| provider::contains_secret(&params, token))
                {
                    return Err("invalid_state_commit");
                }
                let request: resident::CommitRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_state_commit")?;
                if (request.domain == "resident" && request.key == "plan")
                    || (request.domain == "inbox" && request.key == "entries") {
                    return Err("invalid_state_commit");
                }
                self.db
                    .call(move |s| {
                        let tx = s
                            .connection
                            .transaction()
                            .map_err(|_| "storage_unavailable")?;
                        let result = resident::commit(&tx, &request).map_err(|e| e.code)?;
                        tx.commit().map_err(|_| "storage_unavailable")?;
                        // G1: a state write must push. Every domain that commits
                        // through `state_commit` (inbox, resident, world, ...) is
                        // otherwise invisible to subscribers, and "event driven"
                        // would be empty for the whole unified state contract.
                        s.changed.send_modify(|v| *v = v.wrapping_add(1));
                        Ok(json!({"revision": result.revision, "replayed": result.replayed}))
                    })
                    .await
            }
            // 只读能力契约：由权威按自己的常量生成，MCP 面原样转述。
            // 无参数、不读也不写任何状态，因此不需要授权，也不推进任何游标。
            // 见 `contract.rs`：转述者不得自带一份数字，否则 agent 读到的是
            // 一份校验器并不执行的契约。
            "capability_contract" => Ok(contract::describe()),
            "placement_evaluate" => {
                let request: crate::placement::EvaluateRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_placement_request")?;
                let result = tokio::task::spawn_blocking(move || crate::placement::evaluate(request))
                    .await.map_err(|_| "invalid_placement_result")?;
                serde_json::to_value(result)
                    .map_err(|_| "invalid_placement_result")
            }
            "placement_derive" => {
                let request: crate::support_grid::DeriveRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_placement_request")?;
                let result = tokio::task::spawn_blocking(move || crate::support_grid::derive(request))
                    .await.map_err(|_| "invalid_placement_result")?
                    .map_err(|_| "invalid_placement_request")?;
                serde_json::to_value(result).map_err(|_| "invalid_placement_result")
            }
            "world_snapshot" => {
                let request: world::SnapshotRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_world_snapshot")?;
                self.db
                    .call(move |s| world::snapshot(&s.connection, &request))
                    .await
            }
            "world_commit" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_world_commit");
                }
                let request: world::CommitRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_world_commit")?;
                self.db
                    .call(move |s| {
                        let tx = s
                            .connection
                            .transaction()
                            .map_err(|_| "storage_unavailable")?;
                        let result = world::commit(&tx, &request)?;
                        tx.commit().map_err(|_| "storage_unavailable")?;
                        s.changed.send_modify(|v| *v = v.wrapping_add(1));
                        Ok(result)
                    })
                    .await
            }
            "world_import" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_world_import");
                }
                let request: world::ImportRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_world_import")?;
                self.db
                    .call(move |s| {
                        let tx = s
                            .connection
                            .transaction()
                            .map_err(|_| "storage_unavailable")?;
                        let result = world::import(&tx, &request)?;
                        tx.commit().map_err(|_| "storage_unavailable")?;
                        s.changed.send_modify(|v| *v = v.wrapping_add(1));
                        Ok(result)
                    })
                    .await
            }
            "world_facts_read" => {
                let request: world::FactsRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_world_facts_read")?;
                self.db
                    .call(move |s| {
                        let (facts, next) = world::read_facts(&s.connection, &request)?;
                        Ok(json!({"facts": facts, "nextCursor": next}))
                    })
                    .await
            }
            "world_records" => {
                let request: world::RecordsRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_world_records")?;
                self.db
                    .call(move |s| {
                        let records = world::read_records(&s.connection, &request)?;
                        Ok(json!({"records": records}))
                    })
                    .await
            }
            "world_cursors" => {
                let request: world::CursorsRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_world_cursors")?;
                self.db
                    .call(move |s| {
                        let cursors = world::read_cursors(&s.connection, &request.world_id)?;
                        Ok(json!({"cursors": cursors}))
                    })
                    .await
            }
            "world_blob_put" => {
                let request: world::BlobPutRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_world_blob_put")?;
                self.db
                    .call(move |s| {
                        let root = s.root.clone();
                        world::blob_put(&s.connection, &root, &request)
                    })
                    .await
            }
            "world_blob_get" => {
                let request: world::BlobGetRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_world_blob_get")?;
                self.db
                    .call(move |s| world::blob_get(&s.connection, &s.root, &request))
                    .await
            }
            "event_read" => {
                let request: resident::EventReadRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_event_read")?;
                let (after, limit) =
                    resident::read_window(request.after, request.limit).map_err(|e| e.code)?;
                self.db
                    .call(move |s| {
                        let (events, next) =
                            resident::read_events(&s.connection, &request.scope, after, limit)
                                .map_err(|e| e.code)?;
                        Ok(json!({"events": events, "nextCursor": next}))
                    })
                    .await
            }
            "message_read" => {
                let request: resident::MessageReadRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_message_read")?;
                let (after, limit) =
                    resident::read_window(request.after, request.limit).map_err(|e| e.code)?;
                self.db
                    .call(move |s| {
                        let (messages, next) = resident::read_messages(
                            &s.connection,
                            &request.scope,
                            &request.consumer,
                            after,
                            limit,
                        )
                        .map_err(|e| e.code)?;
                        Ok(json!({"messages": messages, "nextCursor": next}))
                    })
                    .await
            }
            "message_ack" => {
                let request: resident::AckRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_message_ack")?;
                self.db
                    .call(move |s| {
                        let tx = s
                            .connection
                            .transaction()
                            .map_err(|_| "storage_unavailable")?;
                        resident::ack(&tx, &request.scope, &request.consumer, &request.id)
                            .map_err(|e| e.code)?;
                        tx.commit().map_err(|_| "storage_unavailable")?;
                        Ok(json!({"acknowledged":true}))
                    })
                    .await
            }
            "memory_status" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_memory_status");
                }
                let request: memory::StatusRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_memory_status")?;
                self.memory.status(request.scope).await
            }
            "memory_read" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_memory_read");
                }
                let request: memory::ReadRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_memory_read")?;
                self.memory.read(request.scope).await
            }
            "memory_query" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_memory_query");
                }
                let request: memory::QueryRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_memory_query")?;
                self.memory
                    .query(request.scope, &request.query, request.top_k)
                    .await
            }
            // 原文层已整体移除（见 `voicemem-rust-contract.md` 的「已移除」一节）。
            // 这三个方法**故意不静默变成 `unknown_method`**：老客户端仍然会调用它们，
            // 而"回合原文没能进记忆"必须是一个**说得出口的失败**，不能是"看起来像
            // 拼错了方法名"。所以给一个专门且自解释的错误码。
            //
            // 为什么不改成"接受但丢弃"：那正是用户点名要消灭的形状 —— 静默成功。
            "memory_turn" | "memory_pending" | "memory_ingest" => {
                Err("memory_original_text_layer_removed")
            }
            "memory_recall" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_memory_recall");
                }
                let request: memory::RecallRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_memory_recall")?;
                self.memory
                    .recall(
                        request.scope,
                        &request.query,
                        request.fresh_session.unwrap_or(false),
                        request.fact_limit,
                        request.note_limit,
                    )
                    .await
            }
            _ => Err("unknown_method"),
        }
    }

    /// SSE subscriptions share the committed-database replay/watermark logic.
    /// Install the watch before the initial read, so commits cannot fall in a gap.
    pub(crate) async fn stream_events(&self, request: Request, writer: Writer) -> Result<()> {
        let changed = self.db.changed.subscribe();
        if request.method == "world_subscribe" {
            let world_id = request.params["worldID"].as_str().ok_or("invalid_world_id")?.to_owned();
            let after = request.params["after"].as_i64().filter(|n| *n >= 0).ok_or("invalid_cursor")?;
            if world_id.is_empty() || world_id.len() > world::TOKEN_LIMIT { return Err("invalid_world_id"); }
            self.world_pending(world_id.clone(), after).await?;
            write(&writer, &json!({"id":request.id,"result":{"subscribed":true}})).await?;
            return self.world_stream(world_id, after, changed, writer).await;
        }
        let scope: Option<MessageScope> = if request.method == "subscribe_messages" {
            Some(serde_json::from_value(request.params.clone()).map_err(|_| "invalid_message_scope")?)
        } else { None };
        let cursor = if scope.is_some() { 0 } else {
            request.params["after"].as_i64().filter(|n| *n >= 0).ok_or("invalid_cursor")?
        };
        self.pending(scope.clone(), cursor).await?;
        write(&writer, &json!({"id":request.id,"result":{"subscribed":true}})).await?;
        self.stream(scope, cursor, changed, writer).await
    }
    async fn stream(
        &self,
        scope: Option<MessageScope>,
        mut cursor: i64,
        mut changed: tokio::sync::watch::Receiver<u64>,
        writer: Writer,
    ) -> Result<()> {
        loop {
            changed.borrow_and_update();
            let batch = self.pending(scope.clone(), cursor).await?;
            if !batch.is_empty() {
                for entry in batch {
                    cursor = entry["sequence"].as_i64().ok_or("history_unavailable")?;
                    let envelope = if scope.is_some() {
                        json!({"message":entry})
                    } else {
                        json!({"event":entry})
                    };
                    write(&writer, &envelope).await?;
                }
                continue;
            }
            changed.changed().await.map_err(|_| "storage_unavailable")?;
        }
    }
    async fn world_pending(&self, world_id: String, after: i64) -> Result<Vec<Value>> {
        self.db
            .call(move |s| {
                let request = world::FactsRequest {
                    world_id,
                    after: Some(after),
                    limit: Some(256),
                };
                let (facts, _) = world::read_facts(&s.connection, &request)?;
                Ok(facts)
            })
            .await
    }
    /// The world event channel: push facts (each with `seq`, `revision` and its
    /// idempotency key) to one subscriber. A dropped watch is not a lost event —
    /// the loop always re-reads the committed database from its cursor.
    async fn world_stream(
        &self,
        world_id: String,
        mut cursor: i64,
        mut changed: tokio::sync::watch::Receiver<u64>,
        writer: Writer,
    ) -> Result<()> {
        loop {
            changed.borrow_and_update();
            let batch = self.world_pending(world_id.clone(), cursor).await?;
            if !batch.is_empty() {
                for entry in batch {
                    cursor = entry["seq"].as_i64().ok_or("history_unavailable")?;
                    write(&writer, &json!({"worldFact": entry})).await?;
                }
                continue;
            }
            changed.changed().await.map_err(|_| "storage_unavailable")?;
        }
    }
    async fn pending(&self, scope: Option<MessageScope>, after: i64) -> Result<Vec<Value>> {
        self.db
            .call(move |s| match scope {
                None => s.events(after),
                Some(scope) => messages::pending_after(
                    &s.connection,
                    &scope.consumer,
                    &scope.world_id,
                    &scope.resident_scope,
                    after,
                    128,
                )
                .map_err(|e| e.code)?
                .into_iter()
                .map(|m| serde_json::to_value(m).map_err(|_| "history_unavailable"))
                .collect(),
            })
            .await
    }

    /// 一次"取产物"要拿到的全部字节：模型，加上**回执声明了才会去取**的碰撞代理。
    ///
    /// 为什么先把两样都取完、核验完再落盘：声明了代理却只落盘模型，会让世界拿到一个
    /// "看起来 ready、其实碰撞数据缺失"的产物；反过来先落模型再取代理失败，也是如此。
    /// 所以这里要么两样都成功，要么整体失败（调用方写 `interrupted` + 可读错误码）。
    ///
    /// 回执**没有**碰撞字段时（今天所有后端都是这样）这里只会发一条模型请求，
    /// 返回 `None` —— 线上请求字节与落盘结果和改造前完全一致。
    async fn fetch_artifact(
        &self,
        job: &model::Job,
        token: &str,
    ) -> Result<(Vec<u8>, Option<Vec<u8>>)> {
        let model = self.provider.fetch_model(job, token).await?;
        let receipt = job.receipt.as_ref().ok_or("missing_receipt")?;
        if !model::declares_collision(receipt)? {
            return Ok((model, None));
        }
        let collision = self.provider.fetch_collision(job, token).await?;
        Ok((model, Some(collision)))
    }

    async fn step(&self, stored: Stored, token: String) -> Result<()> {
        let job = stored.job;
        let id = job.id.clone();
        let download = job.backend_stage == "downloading" && !job.cancel_requested;
        let submit = job.receipt.is_none();
        if download {
            let result = self.fetch_artifact(&job, &token).await;
            self.db
                .call(move |s| {
                    let mut current = s.get(&id)?;
                    if current.job.cancel_requested {
                        return Ok(());
                    }
                    match result {
                        // `None` 只在回执**没有**碰撞字段时出现 —— 那条路上这里与今天逐字节一致。
                        Ok((bytes, collision)) => {
                            let path = s.root.join(format!("{}.glb", id));
                            files::publish(&path, &bytes)?;
                            current.job.local_model_path = Some(path.to_string_lossy().into());
                            current.job.local_collision_path = match collision {
                                Some(bytes) => {
                                    let path = s.root.join(format!("{}.collider.glb", id));
                                    files::publish(&path, &bytes)?;
                                    Some(path.to_string_lossy().into())
                                }
                                None => None,
                            };
                            current.job.backend_stage = "ready".into();
                            current.job.last_error = None;
                        }
                        // 声明了代理却拿不到/核验不过 ⇒ **可见失败**，不落盘半个产物，
                        // 更不会退回 yaw 盒子（那会让碰撞形状在用户不知情下变掉）。
                        Err(code) => {
                            current.job.local_model_path = None;
                            current.job.local_collision_path = None;
                            current.job.backend_stage = "interrupted".into();
                            current.job.last_error = Some(code.into());
                        }
                    }
                    s.save(&current)
                })
                .await?;
        } else {
            // Same three-way dispatch the pre-trait `provider::request(client,
            // job, token, submit, cancel)` call expressed with two booleans:
            // first contact is a submit, afterwards an explicit cancel request
            // takes precedence over polling.
            let result = if submit {
                self.provider.submit(&job, &token).await
            } else if job.cancel_requested {
                self.provider.cancel(&job, &token).await
            } else {
                self.provider.status(&job, &token).await
            };
            self.db
                .call(move |s| {
                    let mut current = s.get(&id)?;
                    match result {
                        Ok(receipt) => {
                            current.job.receipt = Some(receipt);
                            current.job.last_error = None;
                            current.job.backend_stage = model::stage(&current.job).into();
                            if current.job.cancel_requested
                                && !submit
                                && current
                                    .job
                                    .receipt
                                    .as_ref()
                                    .is_some_and(|r| r["state"] == "completed")
                            {
                                current.job.backend_stage = "interrupted".into();
                                current.job.last_error = Some("cancellation_too_late".into());
                            }
                        }
                        Err(code) => {
                            current.job.last_error = Some(code.into());
                            if submit {
                                current.job.backend_stage = if code == "request_rejected" {
                                    "failed"
                                } else {
                                    "submission_uncertain"
                                }
                                .into();
                            } else if ![
                                "network_unavailable",
                                "remote_unavailable",
                                "authentication_required",
                            ]
                            .contains(&code)
                            {
                                current.job.backend_stage = "interrupted".into();
                            }
                        }
                    }
                    s.save(&current)
                })
                .await?;
        }
        Ok(())
    }

    pub(crate) async fn schedule(self, concurrency: usize) -> Result<()> {
        let mut running = JoinSet::new();
        let mut active = HashSet::new();
        let mut due = HashMap::new();
        let mut tick = tokio::time::interval(Duration::from_millis(100));
        let mut rotation = 0;
        loop {
            tokio::select! {
                Some(result) = running.join_next(), if !running.is_empty() => {
                    let (id, result) = result.map_err(|_| "worker_failed")?;
                    active.remove(&id);
                    due.insert(id, Instant::now() + Duration::from_millis(500));
                    result?;
                }
                _ = tick.tick() => {
                    if active.len() >= concurrency { continue; }
                    let mut jobs = self.db.call(|s| s.all()).await?;
                    let len = jobs.len();
                    if len > 0 { jobs.rotate_left(rotation % len); rotation = rotation.wrapping_add(1); }
                    for mut value in jobs {
                        if active.len() >= concurrency { break; }
                        let id = value.job.id.clone();
                        if active.contains(&id) || due.get(&id).is_some_and(|at| *at > Instant::now()) { continue; }
                        if !["queued", "awaiting_configuration", "running", "downloading", "cancel_requested"].contains(&value.job.backend_stage.as_str()) { continue; }
                        // Unknown submission is never automatically reissued, even after cancellation.
                        if value.job.receipt.is_none() && value.attempted && value.job.backend_stage == "cancel_requested" { continue; }
                        let token = self.credentials.read().await.get(&value.job.endpoint).cloned();
                        let Some(token) = token else {
                            if value.job.backend_stage != "awaiting_configuration" {
                                self.db.call(move |s| {
                                    let mut latest = s.get(&id)?;
                                    if latest.job.backend_stage != "cancelled" { latest.job.backend_stage = "awaiting_configuration".into(); s.save(&latest)?; }
                                    Ok(())
                                }).await?;
                            }
                            continue;
                        };
                        // Persist the network boundary on the writer, merging any concurrent cancel.
                        let selected = self.db.call(move |s| {
                            let mut latest = s.get(&id)?;
                            if ["cancelled", "ready", "failed", "interrupted", "submission_uncertain"].contains(&latest.job.backend_stage.as_str()) { return Ok(None); }
                            if latest.job.receipt.is_none() { latest.job.backend_stage = "submitting".into(); latest.attempted = true; }
                            else { latest.job.backend_stage = model::stage(&latest.job).into(); }
                            s.save(&latest)?;
                            Ok(Some(latest))
                        }).await?;
                        let Some(selected) = selected else { continue; };
                        value = selected;
                        let id = value.job.id.clone();
                        active.insert(id.clone());
                        let service = self.clone();
                        running.spawn(async move { let result = service.step(value, token).await; (id, result) });
                    }
                }
            }
        }
    }
}

/// Bounded response producer. HTTP owns serialization/flow control, including
/// cancellation-safe complete SSE messages. Completion is signalled only when
/// the HTTP body consumer takes this frame.
pub(crate) struct OutboundFrame {
    pub bytes: Vec<u8>,
    pub completion: tokio::sync::oneshot::Sender<Result<()>>,
}
#[derive(Clone)]
pub(crate) struct Writer {
    frames: tokio::sync::mpsc::Sender<OutboundFrame>,
    sse: bool,
}
pub(crate) fn response_queue(sse: bool) -> (Writer, tokio::sync::mpsc::Receiver<OutboundFrame>) {
    let (frames, receiver) = tokio::sync::mpsc::channel(8);
    (Writer { frames, sse }, receiver)
}
pub(crate) async fn write(writer: &Writer, value: &Value) -> Result<()> {
    let payload = serde_json::to_vec(value).map_err(|_| "invalid_response")?;
    if payload.len() > FRAME_LIMIT { return Err("frame_too_large"); }
    let bytes = if writer.sse {
        let mut bytes = b"data: ".to_vec();
        bytes.extend(payload);
        bytes.extend(b"\n\n");
        bytes
    } else { payload };
    let (completion, completed) = tokio::sync::oneshot::channel();
    tokio::time::timeout(Duration::from_secs(60), async {
        writer.frames.send(OutboundFrame { bytes, completion }).await.map_err(|_| "client_disconnected")?;
        completed.await.map_err(|_| "client_disconnected")?
    }).await.map_err(|_| "client_timeout")?
}

pub struct Options {
    pub root: PathBuf,
    pub endpoint_file: PathBuf,
    pub legacy: Option<PathBuf>,
    pub concurrency: usize,
    pub media: Option<crate::media::Helpers>,
}
pub fn options() -> Result<Options> {
    let mut root = None;
    let mut endpoint_file = None;
    let mut legacy = None;
    let mut concurrency = 2;
    let mut media_helper = None;
    let mut media_helper_hash = None;
    let mut media_deno = None;
    let mut media_deno_hash = None;
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        let next = args.next().ok_or("invalid_arguments")?;
        match arg.to_str() {
            Some("--root") => root = Some(PathBuf::from(next)),
            Some("--endpoint-file") => endpoint_file = Some(PathBuf::from(next)),
            Some("--legacy-root") => legacy = Some(PathBuf::from(next)),
            Some("--media-helper") => media_helper = Some(PathBuf::from(next)),
            Some("--media-helper-sha256") => media_helper_hash = next.to_str().map(str::to_owned),
            Some("--media-deno") => media_deno = Some(PathBuf::from(next)),
            Some("--media-deno-sha256") => media_deno_hash = next.to_str().map(str::to_owned),
            Some("--concurrency") => {
                concurrency = next
                    .to_str()
                    .and_then(|s| s.parse::<usize>().ok())
                    .filter(|n| (1..=32).contains(n))
                    .ok_or("invalid_concurrency")?
            }
            _ => return Err("invalid_arguments"),
        }
    }
    let root = root.or_else(default_root).ok_or("missing_root")?;
    let endpoint_file = endpoint_file.unwrap_or_else(|| root.join("taskd.endpoint.json"));
    if !root.is_absolute()
        || !endpoint_file.is_absolute()
        || legacy.as_ref().is_some_and(|p| !p.is_absolute())
    {
        return Err("absolute_path_required");
    }
    let media = match (media_helper, media_helper_hash, media_deno, media_deno_hash) {
        (None, None, None, None) => None,
        (Some(helper), Some(helper_sha256), Some(deno), Some(deno_sha256)) =>
            Some(crate::media::Helpers { helper, helper_sha256, deno, deno_sha256 }),
        _ => return Err("invalid_media_helper_config"),
    };
    Ok(Options {
        root,
        endpoint_file,
        legacy,
        concurrency,
        media,
    })
}

fn default_root() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(|base| PathBuf::from(base).join("gmgn radio/TaskService"))
    }
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME").map(|base| {
            PathBuf::from(base).join("Library/Application Support/gmgn radio/TaskService")
        })
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|base| PathBuf::from(base).join(".local/share"))
            })
            .map(|base| base.join("gmgn-radio/TaskService"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // Transport authentication, independent replies, cancellation and voice
    // events are exercised through real HTTP connections in http.rs tests.

    use crate::provider::testwire::serve_once;

    const PNG_BASE64: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=";

    async fn service() -> (Service, PathBuf) {
        let dir = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-daemon-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let service = Service::new(Database::open(dir.clone(), None).unwrap()).unwrap();
        (service, dir)
    }

    fn submission(wish: &str) -> Value {
        json!({
            "id": uuid::Uuid::new_v4().to_string(),
            "endpoint": "https://primary.invalid",
            "name": "wish-prop",
            "pngBase64": PNG_BASE64,
            "source": {"author": "resident", "license": "CC0-1.0"},
            "heightMeters": 0.5,
            "sourceWishID": wish,
            "generationProfile": {"resolution": 512, "decimation": 200000, "textureSize": 2048, "remesh": true},
        })
    }

    /// 尺寸意图穿过**请求边界**（而不是只在 `Submit::validate` 里成立）：
    /// 提交时带意图 ⇒ 任务回执原样回显；类型非法 ⇒ 明确的错误码，不静默收下。
    #[tokio::test]
    async fn submit_carries_and_echoes_the_size_intent_or_rejects_it_by_name() {
        let (service, dir) = service().await;
        let mut params = submission("wish-sword");
        params["heightMeters"] = json!(1.1);
        params["sizeIntent"] = json!({"axis": "longest", "meters": 1.1, "source": "user"});
        let submitted = service.request("submit", params).await.unwrap();
        assert_eq!(submitted["job"]["sizeIntent"]["axis"], "longest");
        assert_eq!(submitted["job"]["sizeIntent"]["meters"], 1.1);
        assert_eq!(submitted["job"]["heightMeters"], 1.1);

        // 轴名不在契约里 / 高度与 height_meters 矛盾 ⇒ 各自的明确错误码。
        for (intent, code) in [
            (
                json!({"axis": "width", "meters": 1.1, "source": "user"}),
                "invalid_size_intent",
            ),
            (
                json!({"axis": "height", "meters": 0.5, "source": "user"}),
                "size_intent_conflict",
            ),
        ] {
            let mut params = submission("wish-2");
            params["heightMeters"] = json!(1.1);
            params["sizeIntent"] = intent.clone();
            assert_eq!(
                service.request("submit", params).await.err(),
                Some(code),
                "sizeIntent = {intent} 被静默收下了"
            );
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn gmgn_state_hash(state: &Value) -> String {
        use sha2::Digest;
        let mut hasher = sha2::Sha256::new();
        hasher.update(serde_json::to_string(state).unwrap().as_bytes());
        format!("{:x}", hasher.finalize())
    }

    /// G1: a `state_commit` must wake subscribers. Every domain that writes
    /// through the unified state contract is otherwise invisible to an
    /// event-driven client, which is exactly the gap this migration has to close
    /// before world state can move onto that contract.
    #[tokio::test]
    async fn state_commit_wakes_subscribers() {
        let (service, dir) = service().await;
        let mut changed = service.db.changed.subscribe();
        // Mark the current value as seen, or `changed()` would return at once
        // and the assertion would pass without any notification at all.
        changed.borrow_and_update();
        let committed = service
            .request(
                "state_commit",
                json!({
                    "scope": {"worldID": "world-a", "residentScope": "resident-a"},
                    "domain": "resident",
                    "key": "test-projection",
                    "expectedRevision": 0,
                    "requestID": uuid::Uuid::new_v4().to_string(),
                    "value": {"entries": []},
                }),
            )
            .await
            .unwrap();
        assert_eq!(committed["revision"], 1);
        tokio::time::timeout(std::time::Duration::from_secs(2), changed.changed())
            .await
            .expect("state_commit did not notify subscribers (G1)")
            .expect("watch channel closed");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The world authority's own commit must push too: the event channel is the
    /// only thing that makes a second client converge without polling.
    #[tokio::test]
    async fn world_commit_wakes_subscribers_and_appends_a_fact() {
        let (service, dir) = service().await;
        let world_id = "world-a";
        let state = json!({
            "worldID": world_id,
            "revision": 1,
            "weather": "clear",
            "objectStates": {},
        });
        service
            .request(
                "world_import",
                json!({
                    "worldID": world_id,
                    "requestID": "import-1",
                    "packageID": "fixture",
                    "packageVersion": "1.0.0",
                    "stateSha256": gmgn_state_hash(&state),
                    "stateJson": serde_json::to_string(&state).unwrap(),
                }),
            )
            .await
            .unwrap();
        let mut changed = service.db.changed.subscribe();
        changed.borrow_and_update();
        let committed = service
            .request(
                "world_commit",
                json!({
                    "worldID": world_id,
                    "requestID": "commit-1",
                    "expectedRevision": 1,
                    "ops": [{"op": "setWorldFacts", "facts": {"weather": "rain", "revision": 2}}],
                }),
            )
            .await
            .unwrap();
        assert_eq!(committed["revision"], 2);
        tokio::time::timeout(std::time::Duration::from_secs(2), changed.changed())
            .await
            .expect("world_commit did not notify subscribers")
            .expect("watch channel closed");
        let facts = service
            .request("world_facts_read", json!({"worldID": world_id, "after": 0}))
            .await
            .unwrap();
        let kinds: Vec<String> = facts["facts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|fact| fact["kind"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(kinds, vec!["world.imported", "world.stateCommitted"]);
        // A stale commit is refused with a visible code, never silently applied.
        let stale = service
            .request(
                "world_commit",
                json!({
                    "worldID": world_id,
                    "requestID": "commit-2",
                    "expectedRevision": 1,
                    "ops": [{"op": "setWorldFacts", "facts": {"weather": "snow"}}],
                }),
            )
            .await;
        assert_eq!(stale.err(), Some("revision_conflict"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Read-only and offline: it describes the bound backend and every origin
    /// that has a credential or a job, and never echoes a token.
    #[tokio::test]
    async fn providers_status_reports_the_bound_backend_without_network() {
        let (service, dir) = service().await;
        let status = service
            .request("providers_status", json!({}))
            .await
            .unwrap();
        assert_eq!(status["provider"]["kind"], "remote_http");
        assert_eq!(status["provider"]["max_input_px"], 2048);
        assert_eq!(status["provider"]["uploads_data"], true);
        assert_eq!(status["endpoints"], json!([]));

        service
            .request(
                "configure",
                json!({"endpoint": "https://dgx.invalid", "token": "secret-probe-token"}),
            )
            .await
            .unwrap();
        let submitted = service
            .request("submit", submission("wish-1"))
            .await
            .unwrap();
        let id = submitted["job"]["id"].as_str().unwrap().to_owned();
        let status = service
            .request("providers_status", json!({}))
            .await
            .unwrap();
        assert_eq!(
            status["endpoints"],
            json!([
                {"endpoint": "https://dgx.invalid", "configured": true, "jobs": 0, "activeJobs": 0},
                {"endpoint": "https://primary.invalid", "configured": false, "jobs": 1, "activeJobs": 1},
            ])
        );
        assert_eq!(status["endpoints"][1]["jobs"], 1);
        service.request("cancel", json!({"id": id})).await.unwrap();
        let status = service
            .request("providers_status", json!({}))
            .await
            .unwrap();
        assert_eq!(status["endpoints"][1]["activeJobs"], 0);
        assert!(!serde_json::to_string(&status)
            .unwrap()
            .contains("secret-probe-token"));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Negotiation in both directions: a health response without the optional
    /// `provider` block behaves exactly as before, and one with the block
    /// decides readiness and the input limit by field.
    #[tokio::test]
    async fn provider_probe_negotiates_health_and_input_limits() {
        let (service, dir) = service().await;
        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            br#"{"status":"api_ready","generation":{"ready":true}}"#.to_vec(),
        )
        .await;
        let probed = service
            .request(
                "provider_probe",
                json!({"endpoint": origin, "inputPx": 2048}),
            )
            .await
            .unwrap();
        let _ = server.await;
        assert_eq!(probed["ready"], true);
        assert_eq!(probed["acceptsInputPx"], true);
        assert_eq!(probed["capabilities"], json!({}));

        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            br#"{"status":"api_ready","generation":{"ready":true},"provider":{"id":"local","max_input_px":512,"ready":false,"reason":"gpu busy"}}"#.to_vec(),
        )
        .await;
        let probed = service
            .request(
                "provider_probe",
                json!({"endpoint": origin, "inputPx": 2048}),
            )
            .await
            .unwrap();
        let _ = server.await;
        assert_eq!(probed["ready"], false);
        assert_eq!(probed["capabilities"]["reason"], "gpu busy");
        assert_eq!(probed["acceptsInputPx"], false);

        // 「收不收得下尺寸意图」也要能被 app 看见：声明缺失时回给 app 的能力块里
        // **没有**这一位（上一段就是），声明在时逐字带出去。app 据此知道这台服务是
        // "只回显"还是"自己按轴归一" —— 这件事只有服务端说了才算，我们不许替它假设。
        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            br#"{"status":"api_ready","generation":{"ready":true},"provider":{"id":"gmgn-prop-service","kind":"remote_http","size_intent":{"axes":["height","longest"],"min_meters":0.01,"max_meters":3.0,"applies":"echo"}}}"#.to_vec(),
        )
        .await;
        let probed = service
            .request(
                "provider_probe",
                json!({"endpoint": origin, "inputPx": 2048}),
            )
            .await
            .unwrap();
        let _ = server.await;
        assert_eq!(
            probed["capabilities"]["size_intent"],
            json!({"axes": ["height", "longest"], "min_meters": 0.01, "max_meters": 3.0, "applies": "echo"})
        );

        // 声明不合法 ⇒ 整块不可信，探测**明确报错**而不是当成"能力很强"。
        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            br#"{"status":"api_ready","generation":{"ready":true},"provider":{"size_intent":{"axes":["width"],"min_meters":0.01,"max_meters":3.0,"applies":"echo"}}}"#.to_vec(),
        )
        .await;
        assert_eq!(
            service
                .request(
                    "provider_probe",
                    json!({"endpoint": origin, "inputPx": 2048})
                )
                .await,
            Err("invalid_provider_capabilities")
        );
        let _ = server.await;

        // A backend whose health is not the shipped api_ready contract is
        // reported, never assumed ready.
        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            br#"{"status":"ok","backend":"mlx"}"#.to_vec(),
        )
        .await;
        assert_eq!(
            service
                .request("provider_probe", json!({"endpoint": origin}))
                .await
                .err(),
            Some("provider_not_ready")
        );
        let _ = server.await;
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The fallback half of the "one wish, one artifact" gate: a drifting
    /// fingerprint is refused, an identical one opens exactly one replacement.
    #[tokio::test]
    async fn failover_http_refuses_profile_drift_and_keeps_one_active_job() {
        let (service, dir) = service().await;
        let submitted = service
            .request("submit", submission("wish-1"))
            .await
            .unwrap();
        let id = submitted["job"]["id"].as_str().unwrap().to_owned();
        let source_key = submitted["job"]["idempotencyKey"]
            .as_str()
            .unwrap()
            .to_owned();

        assert_eq!(
            service
                .request(
                    "failover",
                    json!({"id": id, "endpoint": "https://backup.invalid", "generationProfile": {"resolution": 1024, "decimation": 200000, "textureSize": 2048, "remesh": true}}),
                )
                .await
                .err(),
            Some("fallback_profile_mismatch_would_change_collision_box")
        );
        assert_eq!(
            service
                .request(
                    "failover",
                    json!({"id": id, "endpoint": "https://backup.invalid", "generationProfile": {"resolution": 512, "decimation": 200000, "textureSize": 4096, "remesh": true}}),
                )
                .await
                .err(),
            Some("fallback_profile_mismatch_would_change_collision_box")
        );

        let replaced = service
            .request(
                "failover",
                json!({"id": id, "endpoint": "https://backup.invalid", "generationProfile": {"resolution": 512, "decimation": 200000, "textureSize": 2048, "remesh": true}}),
            )
            .await
            .unwrap();
        assert_eq!(replaced["replaced"]["backendStage"], "cancelled");
        assert_eq!(replaced["job"]["sourceWishID"], "wish-1");
        assert_eq!(
            replaced["job"]["workflowProfile"],
            "gmgn-mesh-v1;resolution=512;decimation=200000;texture_size=2048;remesh=true"
        );
        assert_eq!(
            replaced["job"]["idempotencyKey"],
            format!("{source_key}-r1")
        );
        let jobs = service.db.call(|s| s.all()).await.unwrap();
        assert_eq!(
            jobs.iter()
                .filter(
                    |value| value.job.source_wish_id.as_deref() == Some("wish-1")
                        && model::is_active(&value.job)
                )
                .count(),
            1
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn oversized_outbound_frames_are_rejected_before_writing() {
        let (writer, mut receiver) = response_queue(true);
        let result = write(&writer, &json!({"value":"x".repeat(FRAME_LIMIT)})).await;
        drop(writer);
        assert_eq!(result, Err("frame_too_large"));
        assert!(receiver.recv().await.is_none());
    }
    #[tokio::test]
    async fn canceled_sse_producer_cannot_splice_the_next_event() {
        let (writer,mut receiver) = response_queue(true);
        let first = writer.clone();
        let producer = tokio::spawn(async move {write(&first,&json!({"event":{"payload":"x".repeat(8*1024*1024)}})).await});
        let frame = receiver.recv().await.unwrap();
        producer.abort();
        let _ = producer.await;
        let second = tokio::spawn(async move {write(&writer,&json!({"id":"next","result":true})).await});
        assert!(frame.bytes.starts_with(b"data: ") && frame.bytes.ends_with(b"\n\n"));
        let payload: Value = serde_json::from_slice(&frame.bytes[6..frame.bytes.len()-2]).unwrap();
        assert_eq!(payload["event"]["payload"].as_str().unwrap().len(),8*1024*1024);
        let next = receiver.recv().await.unwrap();
        let payload: Value = serde_json::from_slice(&next.bytes[6..next.bytes.len()-2]).unwrap();
        assert_eq!(payload["id"],"next");
        let _ = next.completion.send(Ok(()));
        assert_eq!(second.await.unwrap(),Ok(()));
    }

    /// 本地记忆方法仍然可用，并且只汇报本地字段：没有 provider 配置、没有压缩
    /// 编排，也没有压缩调度状态。
    ///
    /// 为什么还要探一个不存在的 memory 方法：外部 provider 层的两个方法是被整体
    /// 删除的（没有兼容分支、没有假装成功的兜底），所以这里断言"不属于本地集合的
    /// memory_* 调用一律 unknown_method"。源码里刻意不再写出被删方法的名字，
    /// 便于用 grep 直接验证 provider 层已经不存在。
    #[tokio::test]
    async fn local_memory_methods_report_local_fields_only() {
        let dir = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-daemon-local-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let service = Service::new(Database::open(dir.clone(), None).unwrap()).unwrap();
        let scope = json!({"scope": {"worldID": "install", "residentScope": "install"}});
        assert_eq!(
            service
                .request("memory_provider_configuration", json!({}))
                .await,
            Err("unknown_method")
        );

        assert_eq!(
            service
                .request("memory_status", scope.clone())
                .await
                .unwrap(),
            json!({"memory": null, "pendingTurns": 0})
        );
        // 原文层已整体移除：这三个方法**必须给出一个说得出口的失败**，
        // 而不是"接受但丢弃"（静默成功正是要消灭的形状），也不是含糊的
        // `unknown_method`（老客户端会以为是自己拼错了方法名）。
        for method in ["memory_turn", "memory_pending", "memory_ingest"] {
            let params = match method {
                "memory_turn" => json!({
                    "scope": {"worldID": "install", "residentScope": "install"},
                    "role": "user", "text": "不该被写入的原文",
                }),
                "memory_ingest" => json!({
                    "scope": {"worldID": "install", "residentScope": "install"},
                    "requestID": uuid::Uuid::new_v4().hyphenated().to_string(),
                    "userText": "不该被写入的原文",
                    "agentReply": "也不该",
                }),
                _ => json!({"scope": {"worldID": "install", "residentScope": "install"}}),
            };
            assert_eq!(
                service.request(method, params).await,
                Err("memory_original_text_layer_removed"),
                "{method} 必须显式报告原文层已移除"
            );
        }
        // 语义检索一侧没有 provider，就如实报 unconfigured + 空结果，绝不假检索。
        let recall = service
            .request(
                "memory_recall",
                json!({
                    "scope": {"worldID": "install", "residentScope": "install"},
                    "query": "本地记忆",
                    "freshSession": false,
                }),
            )
            .await
            .unwrap();
        assert_eq!(recall["status"], "unconfigured");
        assert_eq!(recall["facts"], json!([]));
        assert_eq!(recall["notes"], json!([]));
        assert_eq!(recall["pendingTurns"], 0, "原文层已移除：恒为 0");
        assert_eq!(
            service
                .request(
                    "memory_query",
                    json!({
                        "scope": {"worldID": "install", "residentScope": "install"},
                        "query": "本地记忆",
                    }),
                )
                .await
                .unwrap(),
            json!({"status": "unconfigured", "results": []})
        );
        // 被拒的原文投递不能留下任何痕迹：status 仍然说 0 个 pending。
        let status = service.request("memory_status", scope).await.unwrap();
        assert_eq!(status["pendingTurns"], 0);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
