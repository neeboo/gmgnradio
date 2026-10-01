use crate::{
    files, memory, messages,
    model::{self, Result, Stored, Submit, FRAME_LIMIT},
    provider, resident,
    store::Database,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Mutex, RwLock, Semaphore},
    task::JoinSet,
};

#[derive(Clone)]
pub struct Service {
    pub db: Database,
    credentials: Arc<RwLock<HashMap<String, String>>>,
    memory: Arc<memory::Memory>,
    /// The generation backend this daemon is bound to. Scheduling, cancellation
    /// bookkeeping, integrity checks and local storage stay here; the backend
    /// owns only the remote calls behind [`provider::PropProvider`].
    provider: Arc<dyn provider::PropProvider>,
}
#[derive(Deserialize)]
struct Request {
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
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
    /// scheduler and IPC surface without a network.
    pub fn with_provider(db: Database, provider: Arc<dyn provider::PropProvider>) -> Result<Self> {
        Ok(Self {
            db: db.clone(),
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
    async fn request(&self, method: &str, params: Value) -> Result<Value> {
        match method {
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
                let endpoint = params["endpoint"].as_str().ok_or("invalid_endpoint")?.to_owned();
                let profile: Option<model::GenerationProfile> = match params.get("generationProfile")
                {
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
                Ok(json!({"endpoint":endpoint,"ready":ready,"acceptsInputPx":accepts_input_px,"capabilities":capabilities}))
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
                self.db
                    .call(move |s| {
                        let tx = s
                            .connection
                            .transaction()
                            .map_err(|_| "storage_unavailable")?;
                        let result = resident::commit(&tx, &request).map_err(|e| e.code)?;
                        tx.commit().map_err(|_| "storage_unavailable")?;
                        Ok(json!({"revision": result.revision, "replayed": result.replayed}))
                    })
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
            "memory_turn" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_memory_turn");
                }
                let request: memory::TurnRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_memory_turn")?;
                self.memory
                    .turn(request.scope, &request.role, &request.text, request.interrupted)
                    .await
            }
            "memory_pending" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_memory_pending");
                }
                let request: memory::PendingRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_memory_pending")?;
                self.memory.pending(request.scope).await
            }
            "memory_ingest" => {
                if self.has_configured_secret(&params).await {
                    return Err("invalid_memory_ingest");
                }
                let request: memory::IngestRequest =
                    serde_json::from_value(params).map_err(|_| "invalid_memory_ingest")?;
                self.memory
                    .ingest(
                        request.scope,
                        &request.request_id,
                        &request.user_text,
                        &request.agent_reply,
                        request.source.as_deref().unwrap_or("text"),
                        request.observed_at,
                    )
                    .await
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

    async fn serve_connection(&self, stream: UnixStream) -> Result<()> {
        let (reader, writer) = stream.into_split();
        let writer = Arc::new(Mutex::new(writer));
        let mut reader = BufReader::new(reader);
        // A dedicated reader task assembles request frames and pushes them over
        // a channel. Request handling is decoupled from frame assembly so
        // aborting an in-flight request never drops a partially read pipelined
        // frame, while EOF is still observed concurrently with a running
        // request (a client that vanished stops waiting for a reply it can no
        // longer read).
        enum ReaderEvent {
            Frame(Vec<u8>),
            End,
            Error(&'static str),
        }
        let (frames_tx, mut frames_rx) =
            tokio::sync::mpsc::unbounded_channel::<ReaderEvent>();
        let reader_task = tokio::spawn(async move {
            loop {
                match frame(&mut reader).await {
                    Ok(Some(line)) => {
                        if frames_tx.send(ReaderEvent::Frame(line)).is_err() {
                            break;
                        }
                    }
                    Ok(None) => {
                        let _ = frames_tx.send(ReaderEvent::End);
                        break;
                    }
                    Err(code) => {
                        let _ = frames_tx.send(ReaderEvent::Error(code));
                        break;
                    }
                }
            }
        });
        struct ReaderGuard {
            task: tokio::task::JoinHandle<()>,
        }
        impl Drop for ReaderGuard {
            fn drop(&mut self) {
                self.task.abort();
            }
        }
        let _reader_guard = ReaderGuard { task: reader_task };
        // Subscriptions and request replies share one serialized writer, while the
        // reader task remains available for subsequent commands on this connection.
        let mut subscriptions = JoinSet::new();
        // Frames the client pipelined while an earlier request was still in
        // flight; they are processed in order after it completes.
        let mut queued: VecDeque<Vec<u8>> = VecDeque::new();
        loop {
            // Make sure a request frame is pending (read more only when the
            // queue drained, so pipelined frames keep their order).
            while queued.is_empty() {
                let line = tokio::select! {
                    received = frames_rx.recv() => match received {
                        Some(ReaderEvent::Frame(line)) => Some(line),
                        Some(ReaderEvent::End) => return Ok(()),
                        Some(ReaderEvent::Error(code)) => return Err(code),
                        None => return Err("client_disconnected"),
                    },
                    Some(result) = subscriptions.join_next(), if !subscriptions.is_empty() => {
                        result.map_err(|_| "subscription_failed")??;
                        continue;
                    }
                };
                let Some(line) = line else {
                    continue;
                };
                queued.push_back(line);
            }
            let line = queued.pop_front().expect("queue is non-empty");
            let request: Request = match serde_json::from_slice(&line) {
                Ok(r) => r,
                Err(_) => {
                    write(&writer, &failure(Value::Null, "invalid_request")).await?;
                    continue;
                }
            };
            if !request
                .id
                .as_str()
                .is_some_and(|id| (1..=200).contains(&id.len()))
            {
                write(&writer, &failure(Value::Null, "invalid_request_id")).await?;
                continue;
            }
            if request.method == "subscribe" || request.method == "subscribe_messages" {
                let changed = self.db.changed.subscribe();
                let scope: Option<MessageScope> = if request.method == "subscribe_messages" {
                    match serde_json::from_value(request.params.clone()) {
                        Ok(v) => Some(v),
                        Err(_) => {
                            write(&writer, &failure(request.id, "invalid_message_scope")).await?;
                            continue;
                        }
                    }
                } else {
                    None
                };
                let cursor = if scope.is_some() {
                    0
                } else {
                    match request.params["after"].as_i64().filter(|n| *n >= 0) {
                        Some(n) => n,
                        None => {
                            write(&writer, &failure(request.id, "invalid_cursor")).await?;
                            continue;
                        }
                    }
                };
                // Validate scope and read once before accepting a subscription. The watch receiver
                // is already installed; subsequent reads always use the committed database.
                let initial = self.pending(scope.clone(), cursor).await;
                if let Err(code) = initial {
                    write(&writer, &failure(request.id, code)).await?;
                    continue;
                }
                write(
                    &writer,
                    &json!({"id":request.id,"result":{"subscribed":true}}),
                )
                .await?;
                let service = self.clone();
                let writer = writer.clone();
                subscriptions
                    .spawn(async move { service.stream(scope, cursor, changed, writer).await });
                continue;
            }
            // Run the request on a spawned task so a client disconnect can
            // abort it instead of leaving the connection waiting on a reply
            // nobody will read. While it runs, the reader task's EOF or
            // pipelined frames are observed so later frames keep their order.
            let service = self.clone();
            let method = request.method.clone();
            let params = request.params.clone();
            let mut task = tokio::spawn(async move { service.request(&method, params).await });
            let outcome = loop {
                tokio::select! {
                    outcome = &mut task => break outcome,
                    received = frames_rx.recv() => match received {
                        Some(ReaderEvent::Frame(line)) => queued.push_back(line),
                        Some(ReaderEvent::End) => {
                            // Client disconnected while the request was in
                            // flight: drop the reply and the connection.
                            task.abort();
                            let _ = task.await;
                            return Ok(());
                        }
                        Some(ReaderEvent::Error(code)) => {
                            task.abort();
                            let _ = task.await;
                            return Err(code);
                        }
                        None => {
                            task.abort();
                            let _ = task.await;
                            return Err("client_disconnected");
                        }
                    },
                }
            };
            let result = match outcome {
                Ok(result) => result,
                Err(_) => return Err("worker_failed"),
            };
            let response = match result {
                Ok(result) => json!({"id": request.id, "result": result}),
                Err(code) => failure(request.id, code),
            };
            write(&writer, &response).await?;
        }
    }
    async fn stream(
        &self,
        scope: Option<MessageScope>,
        mut cursor: i64,
        mut changed: tokio::sync::watch::Receiver<u64>,
        writer: Arc<Mutex<tokio::net::unix::OwnedWriteHalf>>,
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

    async fn schedule(self, concurrency: usize) -> Result<()> {
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

pub async fn run(listener: UnixListener, db: Database, concurrency: usize) -> Result<()> {
    let service = Service::new(db)?;
    let mut scheduler = tokio::spawn(service.clone().schedule(concurrency));
    let clients = Arc::new(Semaphore::new(64));
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .map_err(|_| "signal_unavailable")?;
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => return Ok(()),
            _ = term.recv() => return Ok(()),
            result = &mut scheduler => return result.map_err(|_| "worker_failed")?,
            accepted = listener.accept() => {
                let (stream, _) = accepted.map_err(|_| "socket_unavailable")?;
                let Ok(permit) = clients.clone().try_acquire_owned() else { drop(stream); continue; };
                let service = service.clone();
                tokio::spawn(async move { let _permit = permit; let _ = service.serve_connection(stream).await; });
            }
        }
    }
}
fn failure(id: Value, code: &str) -> Value {
    json!({"id":id,"error":{"code":code,"message":code}})
}
async fn write(writer: &Arc<Mutex<tokio::net::unix::OwnedWriteHalf>>, value: &Value) -> Result<()> {
    let mut bytes = serde_json::to_vec(value).map_err(|_| "invalid_response")?;
    bytes.push(b'\n');
    if bytes.len() > FRAME_LIMIT {
        return Err("frame_too_large");
    }
    tokio::time::timeout(Duration::from_secs(60), async {
        writer.lock().await.write_all(&bytes).await
    })
    .await
    .map_err(|_| "client_timeout")?
    .map_err(|_| "client_disconnected")
}
async fn frame(reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>) -> Result<Option<Vec<u8>>> {
    let mut frame = Vec::new();
    loop {
        let buffer = reader.fill_buf().await.map_err(|_| "client_disconnected")?;
        if buffer.is_empty() {
            return if frame.is_empty() {
                Ok(None)
            } else {
                Err("incomplete_frame")
            };
        }
        let count = buffer
            .iter()
            .position(|b| *b == b'\n')
            .map(|n| n + 1)
            .unwrap_or(buffer.len());
        if frame.len() + count > FRAME_LIMIT {
            return Err("frame_too_large");
        }
        let done = buffer[count - 1] == b'\n';
        frame.extend_from_slice(&buffer[..count]);
        reader.consume(count);
        if done {
            return Ok(Some(frame));
        }
    }
}

pub struct Options {
    pub root: PathBuf,
    pub socket: PathBuf,
    pub legacy: Option<PathBuf>,
    pub concurrency: usize,
}
pub fn options() -> Result<Options> {
    let mut root = None;
    let mut socket = None;
    let mut legacy = None;
    let mut concurrency = 2;
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        let next = args.next().ok_or("invalid_arguments")?;
        match arg.to_str() {
            Some("--root") => root = Some(PathBuf::from(next)),
            Some("--socket") => socket = Some(PathBuf::from(next)),
            Some("--legacy-root") => legacy = Some(PathBuf::from(next)),
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
    let root = root
        .or_else(|| {
            std::env::var_os("HOME").map(|h| {
                PathBuf::from(h).join("Library/Application Support/gmgn radio/TaskService")
            })
        })
        .ok_or("missing_root")?;
    let socket = socket.unwrap_or_else(|| root.join("taskd.sock"));
    if !root.is_absolute()
        || !socket.is_absolute()
        || legacy.as_ref().is_some_and(|p| !p.is_absolute())
    {
        return Err("absolute_path_required");
    }
    Ok(Options {
        root,
        socket,
        legacy,
        concurrency,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::provider::testwire::serve_once;

    const PNG_BASE64: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=";

    async fn service() -> (Service, PathBuf) {
        let dir = std::env::temp_dir().join(format!("gmgn-daemon-{}", uuid::Uuid::new_v4()));
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
            (json!({"axis": "width", "meters": 1.1, "source": "user"}), "invalid_size_intent"),
            (json!({"axis": "height", "meters": 0.5, "source": "user"}), "size_intent_conflict"),
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

    /// Read-only and offline: it describes the bound backend and every origin
    /// that has a credential or a job, and never echoes a token.
    #[tokio::test]
    async fn providers_status_reports_the_bound_backend_without_network() {
        let (service, dir) = service().await;
        let status = service.request("providers_status", json!({})).await.unwrap();
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
        let submitted = service.request("submit", submission("wish-1")).await.unwrap();
        let id = submitted["job"]["id"].as_str().unwrap().to_owned();
        let status = service.request("providers_status", json!({})).await.unwrap();
        assert_eq!(
            status["endpoints"],
            json!([
                {"endpoint": "https://dgx.invalid", "configured": true, "jobs": 0, "activeJobs": 0},
                {"endpoint": "https://primary.invalid", "configured": false, "jobs": 1, "activeJobs": 1},
            ])
        );
        assert_eq!(status["endpoints"][1]["jobs"], 1);
        service.request("cancel", json!({"id": id})).await.unwrap();
        let status = service.request("providers_status", json!({})).await.unwrap();
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
            .request("provider_probe", json!({"endpoint": origin, "inputPx": 2048}))
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
            .request("provider_probe", json!({"endpoint": origin, "inputPx": 2048}))
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
            .request("provider_probe", json!({"endpoint": origin, "inputPx": 2048}))
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
                .request("provider_probe", json!({"endpoint": origin, "inputPx": 2048}))
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
    async fn failover_ipc_refuses_profile_drift_and_keeps_one_active_job() {
        let (service, dir) = service().await;
        let submitted = service.request("submit", submission("wish-1")).await.unwrap();
        let id = submitted["job"]["id"].as_str().unwrap().to_owned();
        let source_key = submitted["job"]["idempotencyKey"].as_str().unwrap().to_owned();

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
        assert_eq!(replaced["job"]["idempotencyKey"], format!("{source_key}-r1"));
        let jobs = service.db.call(|s| s.all()).await.unwrap();
        assert_eq!(
            jobs.iter()
                .filter(|value| value.job.source_wish_id.as_deref() == Some("wish-1")
                    && model::is_active(&value.job))
                .count(),
            1
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn oversized_outbound_frames_are_rejected_before_writing() {
        let (socket, mut peer) = UnixStream::pair().unwrap();
        let (_, writer) = socket.into_split();
        let writer = Arc::new(Mutex::new(writer));
        let drain = tokio::spawn(async move {
            tokio::io::copy(&mut peer, &mut tokio::io::sink())
                .await
                .unwrap()
        });
        let result = write(&writer, &json!({"value":"x".repeat(FRAME_LIMIT)})).await;
        drop(writer);
        let count = drain.await.unwrap();
        assert_eq!(result, Err("frame_too_large"));
        assert_eq!(count, 0);
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
        let dir = std::env::temp_dir().join(format!("gmgn-daemon-local-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let service = Service::new(Database::open(dir.clone(), None).unwrap()).unwrap();
        let scope = json!({"scope": {"worldID": "install", "residentScope": "install"}});
        assert_eq!(
            service.request("memory_provider_configuration", json!({})).await,
            Err("unknown_method")
        );

        assert_eq!(
            service.request("memory_status", scope.clone()).await.unwrap(),
            json!({"memory": null, "pendingTurns": 0})
        );
        assert_eq!(
            service
                .request(
                    "memory_ingest",
                    json!({
                        "scope": {"worldID": "install", "residentScope": "install"},
                        "requestID": uuid::Uuid::new_v4().hyphenated().to_string(),
                        "userText": "本地记忆仍然写入",
                        "agentReply": "收到",
                    }),
                )
                .await
                .unwrap(),
            json!({"accepted": true, "replayed": false, "pendingTurns": 2})
        );
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
        let status = service.request("memory_status", scope).await.unwrap();
        assert_eq!(status["pendingTurns"], 2);
        assert_eq!(
            service
                .request("memory_pending", json!({"scope": {"worldID": "install", "residentScope": "install"}}))
                .await
                .unwrap()["turns"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
