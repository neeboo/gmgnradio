//! Plain chat has its own durable scope; it never borrows a resident world claim.
use crate::{files, store::Database};
use gmgn_agent_runtime::{
    chat_cli::{self, ChatBackend, ChatCliConfig, ChatCliRequest, ChatMessage},
    chat_dsh::{self, ChatDshConfig, ChatDshIdentity, ChatDshSession},
    CancellationToken, ImageInput, UserInput,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::sync::{watch, Mutex};
type Result<T> = std::result::Result<T, &'static str>;

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS chat_threads(backend TEXT NOT NULL,scope TEXT NOT NULL,session TEXT,history TEXT NOT NULL DEFAULT '[]',imported INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(backend,scope)); CREATE TABLE IF NOT EXISTS chat_requests(backend TEXT NOT NULL,scope TEXT NOT NULL,request TEXT NOT NULL,host_session TEXT NOT NULL,digest TEXT NOT NULL,state TEXT NOT NULL,reply TEXT,error TEXT,session TEXT,PRIMARY KEY(backend,scope,request));").map_err(|_|"storage_unavailable")
}
pub fn recover(c: &Connection) -> Result<()> {
    c.execute("UPDATE chat_requests SET state='unknown',error='chat_transport_failed' WHERE state='running'",[]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn field(p: &Value, key: &str) -> Result<String> {
    p[key]
        .as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
        .map(str::to_owned)
        .ok_or("agent_chat_invalid_request")
}
fn native(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 1024
        && !s.starts_with('-')
        && !s.chars().any(|c| c.is_control() || c.is_whitespace())
}
struct Active {
    cancel: CancellationToken,
    done: watch::Receiver<bool>,
}
struct DshActor {
    actor: ChatDshSession,
    directory: PathBuf,
    fingerprint: String,
}
type DshSlot = Arc<Mutex<Option<DshActor>>>;
#[derive(Clone)]
pub struct ChatService {
    db: Database,
    active: Arc<Mutex<HashMap<String, Active>>>,
    gate: Arc<Mutex<()>>,
    dsh: Arc<Mutex<HashMap<String, DshSlot>>>,
}
impl ChatService {
    pub fn new(db: Database) -> Self {
        Self {
            db,
            active: Arc::new(Mutex::new(HashMap::new())),
            gate: Arc::new(Mutex::new(())),
            dsh: Arc::new(Mutex::new(HashMap::new())),
        }
    }
    async fn close_dsh(&self, scope: &str) {
        if let Some(slot) = self.dsh.lock().await.remove(scope) {
            if let Some(mut owned) = slot.lock().await.take() {
                owned.actor.close().await;
                let _ = std::fs::remove_dir_all(owned.directory);
            }
        }
    }
    async fn settle(&self, scope: &str) -> Result<()> {
        let done = {
            let active = self.active.lock().await;
            active.get(scope).map(|a| {
                a.cancel.cancel();
                a.done.clone()
            })
        };
        if let Some(mut done) = done {
            while !*done.borrow() {
                done.changed().await.map_err(|_| "agent_chat_unknown")?;
            }
        }
        self.active.lock().await.remove(scope);
        Ok(())
    }
    pub async fn request(&self, method: &str, p: &Value) -> Result<Value> {
        let backend =
            ChatBackend::parse(&field(p, "backend")?).map_err(|_| "agent_chat_invalid_backend")?;
        let name = backend.name().to_owned();
        let scope = field(p, "scopeID")?;
        let host = field(p, "hostSessionID")?;
        match method {
            "agent_chat_read" => {
                if p.get("requestID").is_none() {
                    return self.db.call(move|s| {
                        let row=s.connection.query_row("SELECT session,history FROM chat_threads WHERE backend=?1 AND scope=?2",params![name,scope],|r|Ok((r.get::<_,Option<String>>(0)?,r.get::<_,String>(1)?))).optional().map_err(|_|"storage_unavailable")?;
                        let (session,history)=row.unwrap_or((None,"[]".into()));
                        let count=serde_json::from_str::<Vec<Value>>(&history).map_err(|_|"agent_chat_invalid_history")?.len();
                        Ok(json!({"sessionID":session,"historyCount":count,"freshSession":session.is_none()&&count==0}))
                    }).await;
                }
                let request = field(p, "requestID")?;
                self.db.call(move|s|s.connection.query_row("SELECT host_session,state,reply,error,session FROM chat_requests WHERE backend=?1 AND scope=?2 AND request=?3",params![name,scope,request],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,Option<String>>(2)?,r.get::<_,Option<String>>(3)?,r.get::<_,Option<String>>(4)?))).optional().map_err(|_|"storage_unavailable")?.ok_or("agent_chat_not_found").and_then(|(h,state,reply,error,session)|{if h!=host {Err("agent_chat_stale_session")} else {Ok(json!({"state":state,"reply":reply,"error":error,"sessionID":session}))} })).await
            }
            "agent_chat_cancel" => {
                let _gate = self.gate.lock().await;
                let request = field(p, "requestID")?;
                let key = scope.clone();
                let current=self.db.call(move|s|s.connection.query_row("SELECT host_session,state FROM chat_requests WHERE backend=?1 AND scope=?2 AND request=?3",params![name,scope,request],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).optional().map_err(|_|"storage_unavailable")?.ok_or("agent_chat_not_found")).await?;
                if current.0 != host {
                    return Err("agent_chat_stale_session");
                }
                if current.1 == "running" {
                    self.settle(&key).await?;
                }
                self.close_dsh(&key).await;
                Ok(json!({"cancelled":true}))
            }
            "agent_chat_reset" => {
                let _gate = self.gate.lock().await;
                self.settle(&scope).await?;
                self.close_dsh(&scope).await;
                self.db.call(move|s|{s.connection.execute("INSERT INTO chat_threads(backend,scope,imported) VALUES(?1,?2,1) ON CONFLICT(backend,scope) DO UPDATE SET session=NULL,history='[]',imported=1",params![name,scope]).map_err(|_|"storage_unavailable")?;s.connection.execute("UPDATE chat_requests SET state='failed',error='agent_chat_reset' WHERE scope=?1 AND state='unknown'",params![scope]).map_err(|_|"storage_unavailable")?;Ok(json!({"reset":true}))}).await
            }
            "agent_chat_import" => {
                let session = p
                    .get("sessionID")
                    .filter(|v| !v.is_null())
                    .map(|v| {
                        v.as_str()
                            .filter(|s| native(s))
                            .map(str::to_owned)
                            .ok_or("agent_chat_invalid_session")
                    })
                    .transpose()?;
                let _gate = self.gate.lock().await;
                self.db.call(move|s|{s.connection.execute("INSERT OR IGNORE INTO chat_threads(backend,scope) VALUES(?1,?2)",params![name,scope]).map_err(|_|"storage_unavailable")?;let changed=s.connection.execute("UPDATE chat_threads SET session=?3,imported=1 WHERE backend=?1 AND scope=?2 AND imported=0 AND session IS NULL AND history='[]'",params![name,scope,session]).map_err(|_|"storage_unavailable")?;Ok(json!({"imported":changed==1}))}).await
            }
            "agent_chat_start" => self.start(backend, scope, host, p).await,
            _ => Err("unsupported_method"),
        }
    }
    async fn start(
        &self,
        backend: ChatBackend,
        scope: String,
        host: String,
        p: &Value,
    ) -> Result<Value> {
        let request = field(p, "requestID")?;
        let input = p["input"]
            .as_str()
            .filter(|s| !s.trim().is_empty() && s.len() <= 1_048_576 && !s.contains('\0'))
            .ok_or("agent_chat_invalid_input")?
            .to_owned();
        let user = p
            .get("userText")
            .map(|v| {
                v.as_str()
                    .filter(|s| s.len() <= 32768)
                    .ok_or("agent_chat_invalid_input")
            })
            .transpose()?
            .unwrap_or(&input)
            .to_owned();
        let executable = PathBuf::from(
            p["executable"]
                .as_str()
                .ok_or("agent_chat_invalid_configuration")?,
        );
        if !executable.is_absolute()
            || ["arguments", "permissions", "mcpConfig", "model"]
                .iter()
                .any(|k| p.get(*k).is_some())
        {
            return Err("agent_chat_unsafe_configuration");
        }
        let environment: BTreeMap<String, String> =
            serde_json::from_value(p.get("environment").cloned().unwrap_or(json!({})))
                .map_err(|_| "agent_chat_invalid_configuration")?;
        let allowed = [
            "PATH",
            "TMPDIR",
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "LANG",
            "LC_ALL",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
        ];
        if environment
            .iter()
            .any(|(k, v)| !allowed.contains(&k.as_str()) || v.len() > 32768 || v.contains('\0'))
        {
            return Err("agent_chat_unsafe_configuration");
        }
        let images: Vec<PathBuf> =
            serde_json::from_value(p.get("images").cloned().unwrap_or(json!([])))
                .map_err(|_| "agent_chat_invalid_image")?;
        if images.len() > 4
            || (!images.is_empty() && ![ChatBackend::Codex, ChatBackend::Dsh].contains(&backend))
        {
            return Err("chat_images_unsupported");
        }
        // The host supplies private, already imported images, never arbitrary model paths.
        let root = self.db.root.canonicalize().map_err(|_| "unsafe_path")?;
        for image in &images {
            let path = image
                .canonicalize()
                .map_err(|_| "agent_chat_invalid_image")?;
            if !path.starts_with(&root) {
                return Err("agent_chat_invalid_image");
            }
        }
        let mut typed_images = Vec::new();
        if backend == ChatBackend::Dsh {
            let mut total = 0usize;
            for path in &images {
                let bytes = files::read(path, 4_194_304)?;
                total = total
                    .checked_add(bytes.len())
                    .ok_or("agent_chat_invalid_image")?;
                if total > 4_194_304 {
                    return Err("agent_chat_invalid_image");
                }
                let media = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
                    "image/png"
                } else if bytes.starts_with(b"\xff\xd8\xff") {
                    "image/jpeg"
                } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
                    "image/gif"
                } else if bytes.len() >= 12
                    && bytes.starts_with(b"RIFF")
                    && &bytes[8..12] == b"WEBP"
                {
                    "image/webp"
                } else {
                    return Err("agent_chat_invalid_image");
                };
                typed_images.push(ImageInput {
                    bytes,
                    media_type: media.into(),
                });
            }
        }
        let dsh_entry = if backend == ChatBackend::Dsh {
            let path = PathBuf::from(
                p["dshEntryPoint"]
                    .as_str()
                    .ok_or("agent_chat_invalid_configuration")?,
            );
            if !path.is_absolute() {
                return Err("agent_chat_invalid_configuration");
            }
            Some(path)
        } else {
            None
        };
        let persona = p
            .get("persona")
            .map(|v| {
                v.as_str()
                    .filter(|s| s.len() <= 32768)
                    .map(str::to_owned)
                    .ok_or("agent_chat_invalid_configuration")
            })
            .transpose()?
            .unwrap_or_default();
        let dsh_fingerprint=format!("{:x}",Sha256::digest(serde_json::to_vec(&json!({"node":executable,"entry":dsh_entry,"environment":environment,"persona":persona})).map_err(|_|"agent_chat_invalid_configuration")?));
        let digest = format!(
            "{:x}",
            Sha256::digest(
                serde_json::to_vec(&json!({"input":input,"user":user,"images":images,"imageDigests":typed_images.iter().map(|i|format!("{:x}",Sha256::digest(&i.bytes))).collect::<Vec<_>>(),"host":host,"dshConfiguration":dsh_fingerprint}))
                    .map_err(|_| "agent_chat_invalid_input")?
            )
        );
        let _gate = self.gate.lock().await;
        let name = backend.name().to_owned();
        let (n, sc, r, h, d) = (
            name.clone(),
            scope.clone(),
            request.clone(),
            host.clone(),
            digest.clone(),
        );
        let existing=self.db.call(move|s|s.connection.query_row("SELECT digest,host_session,state FROM chat_requests WHERE backend=?1 AND scope=?2 AND request=?3",params![n,sc,r],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))).optional().map_err(|_|"storage_unavailable").and_then(|v|match v {Some((old,host,state)) if old==d&&host==h=>Ok(Some(state)),Some(_)=>Err("agent_chat_request_conflict"),None=>Ok(None)})).await?;
        if let Some(state) = existing {
            return Ok(json!({"requestID":request,"state":state}));
        }
        self.settle(&scope).await?;
        if backend != ChatBackend::Dsh {
            self.close_dsh(&scope).await;
        } else {
            let slots = self.dsh.lock().await;
            if slots.len() >= 8 && !slots.contains_key(&scope) {
                return Err("agent_chat_capacity");
            }
        }
        if self
            .active
            .lock()
            .await
            .values()
            .filter(|a| !*a.done.borrow())
            .count()
            >= 8
        {
            return Err("agent_chat_capacity");
        }
        let (n, sc) = (name.clone(), scope.clone());
        let (session, history) = self
            .db
            .call(move |s| {
                let unknown: i64 = s
                    .connection
                    .query_row(
                        "SELECT count(*) FROM chat_requests WHERE scope=?1 AND state='unknown'",
                        params![sc],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")?;
                if unknown > 0 {
                    return Err("agent_chat_unknown");
                }
                s.connection
                    .execute(
                        "INSERT OR IGNORE INTO chat_threads(backend,scope) VALUES(?1,?2)",
                        params![n, sc],
                    )
                    .map_err(|_| "storage_unavailable")?;
                s.connection
                    .query_row(
                        "SELECT session,history FROM chat_threads WHERE backend=?1 AND scope=?2",
                        params![n, sc],
                        |r| Ok((r.get::<_, Option<String>>(0)?, r.get::<_, String>(1)?)),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await?;
        let directory = root.join(format!("chat-{}", uuid::Uuid::new_v4()));
        files::directory(&directory)?;
        let cwd = directory.join("cwd");
        files::directory(&cwd)?;
        let claude_config_directory = if backend == ChatBackend::Claude {
            let dir = directory.join("config");
            files::directory(&dir)?;
            Some(dir)
        } else {
            None
        };
        let claude_empty_mcp_config = if backend == ChatBackend::Claude {
            let file = directory.join("mcp.json");
            files::publish(&file, b"{\"mcpServers\":{}}")?;
            Some(file)
        } else {
            None
        };
        let secrets: Vec<String> = environment
            .iter()
            .filter(|(key, _)| key.ends_with("API_KEY"))
            .map(|(_, value)| value.clone())
            .filter(|value| !value.is_empty())
            .collect();
        let config = ChatCliConfig {
            executable,
            environment,
            working_directory: cwd,
            private_root: root,
            lifetime: Duration::from_secs(180),
            claude_empty_mcp_config,
            claude_config_directory,
        };
        let prior: Vec<Value> =
            serde_json::from_str(&history).map_err(|_| "agent_chat_invalid_history")?;
        let cli = ChatCliRequest {
            backend,
            input,
            native_session_id: session,
            fresh_session_id: if backend == ChatBackend::Qoder {
                Some(uuid::Uuid::new_v4().to_string())
            } else {
                None
            },
            history: prior
                .iter()
                .filter_map(|v| {
                    Some(ChatMessage {
                        user: v["user"].as_bool()?,
                        text: v["text"].as_str()?.to_owned(),
                    })
                })
                .collect(),
            images: if backend == ChatBackend::Dsh {
                vec![]
            } else {
                images
            },
        };
        if let Err(error) = if backend == ChatBackend::Dsh {
            Ok((vec![], String::new()))
        } else {
            chat_cli::arguments(&cli, &config)
        } {
            let _ = std::fs::remove_dir_all(&directory);
            return Err(error.code());
        }
        let (n, sc, r, h) = (name.clone(), scope.clone(), request.clone(), host.clone());
        self.db.call(move|s|{s.connection.execute("INSERT INTO chat_requests(backend,scope,request,host_session,digest,state) VALUES(?1,?2,?3,?4,?5,'running')",params![n,sc,r,h,digest]).map_err(|_|"storage_unavailable")?;Ok(())}).await?;
        let cancel = CancellationToken::new();
        let (done_tx, done) = watch::channel(false);
        self.active.lock().await.insert(
            scope.clone(),
            Active {
                cancel: cancel.clone(),
                done,
            },
        );
        let db = self.db.clone();
        let dsh_slot = if backend == ChatBackend::Dsh {
            Some(
                self.dsh
                    .lock()
                    .await
                    .entry(scope.clone())
                    .or_insert_with(|| Arc::new(Mutex::new(None)))
                    .clone(),
            )
        } else {
            None
        };
        let response = json!({"requestID":request,"state":"running"});
        tokio::spawn(async move {
            let mut keep_directory = false;
            let result = if let Some(slot) = dsh_slot {
                let mut owned = slot.lock().await;
                if owned.as_ref().is_some_and(|o| {
                    !o.actor.is_usable()
                        || o.actor.identity().host_session_id != host
                        || o.fingerprint != dsh_fingerprint
                }) {
                    if let Some(mut old) = owned.take() {
                        old.actor.close().await;
                        let _ = std::fs::remove_dir_all(old.directory);
                    }
                }
                let identity = ChatDshIdentity {
                    scope_id: scope.clone(),
                    host_session_id: host.clone(),
                    request_id: request.clone(),
                };
                let mut text = cli.input.clone();
                if owned.is_none() && !cli.history.is_empty() {
                    text = format!(
                        "对话上下文数据（不重放旧动作）：\n{}\n\n{}",
                        cli.history
                            .iter()
                            .map(|h| format!(
                                "{}: {}",
                                if h.user { "用户" } else { "助手" },
                                h.text
                            ))
                            .collect::<Vec<_>>()
                            .join("\n"),
                        text
                    );
                }
                let user_input = UserInput {
                    text,
                    images: typed_images,
                };
                let reply = if let Some(old) = owned.as_mut() {
                    old.actor.turn(identity, user_input, cancel.clone()).await
                } else {
                    let attachment = directory.join("attachments");
                    let persistence = directory.join("sessions");
                    let composition_file = directory.join("composition.yaml");
                    let setup = files::directory(&attachment)
                        .and_then(|_| files::directory(&persistence))
                        .and_then(|_| {
                            chat_dsh::composition(
                                &attachment.to_string_lossy(),
                                &persistence.to_string_lossy(),
                                &persona,
                            )
                            .map_err(|e| e.code())
                        })
                        .and_then(|yaml| files::publish(&composition_file, yaml.as_bytes()));
                    match setup {
                        Err(_) => Err(chat_cli::ChatCliError::InvalidConfiguration),
                        Ok(()) => {
                            let dsh_config = ChatDshConfig {
                                node_executable: config.executable,
                                entry_point: dsh_entry.unwrap(),
                                composition_file,
                                cwd: config.working_directory,
                                environment: config.environment,
                                lifetime: Duration::from_secs(1800),
                                attachment_home: attachment,
                                persistence_root: persistence,
                                persona,
                            };
                            match ChatDshSession::open(
                                dsh_config,
                                identity,
                                user_input,
                                cancel.clone(),
                            )
                            .await
                            {
                                Ok((actor, reply)) => {
                                    *owned = Some(DshActor {
                                        actor,
                                        directory: directory.clone(),
                                        fingerprint: dsh_fingerprint,
                                    });
                                    keep_directory = true;
                                    Ok(reply)
                                }
                                Err(e) => Err(e),
                            }
                        }
                    }
                };
                match reply {
                    Ok(_) if cancel.is_cancelled() => {
                        if let Some(mut old) = owned.take() {
                            old.actor.close().await;
                            let _ = std::fs::remove_dir_all(old.directory);
                        }
                        keep_directory = false;
                        Err(chat_cli::ChatCliError::Cancelled)
                    }
                    Ok(reply) => Ok(chat_cli::ChatCliResult {
                        reply,
                        native_session_id: owned
                            .as_ref()
                            .and_then(|o| o.actor.session_id().map(str::to_owned)),
                    }),
                    Err(e) => {
                        if let Some(mut old) = owned.take() {
                            old.actor.close().await;
                            let _ = std::fs::remove_dir_all(old.directory);
                        }
                        Err(e)
                    }
                }
            } else {
                chat_cli::run(config, cli, cancel.clone()).await
            };
            let result = result.and_then(|out| {
                if secrets.iter().any(|secret| out.reply.contains(secret)) {
                    Err(chat_cli::ChatCliError::InvalidResult)
                } else {
                    Ok(out)
                }
            });
            let cancelled = cancel.is_cancelled();
            let persisted=db.call(move|s|{let tx=s.connection.transaction().map_err(|_|"storage_unavailable")?;
                match result {
                    Ok(out) if !cancelled=>{let mut history=prior;history.push(json!({"user":true,"text":user.chars().take(8000).collect::<String>()}));history.push(json!({"user":false,"text":out.reply.chars().take(8000).collect::<String>()}));if history.len()>6 {history.drain(..history.len()-6);}
                        tx.execute("UPDATE chat_threads SET session=?3,history=?4,imported=1 WHERE backend=?1 AND scope=?2",params![name,scope,out.native_session_id,serde_json::to_string(&history).map_err(|_|"storage_unavailable")?]).map_err(|_|"storage_unavailable")?;
                        tx.execute("UPDATE chat_requests SET state='completed',reply=?4,session=?5 WHERE backend=?1 AND scope=?2 AND request=?3 AND host_session=?6 AND state='running'",params![name,scope,request,out.reply,out.native_session_id,host]).map_err(|_|"storage_unavailable")?;
                    }
                    other=>{let error=match other{Err(e)=>e.code(),_=>"chat_cancelled"};let state=if cancelled {"cancelled"}else if error=="chat_transport_failed" {"unknown"}else{"failed"};tx.execute("UPDATE chat_requests SET state=?4,error=?5 WHERE backend=?1 AND scope=?2 AND request=?3",params![name,scope,request,state,error]).map_err(|_|"storage_unavailable")?;}
                } tx.commit().map_err(|_|"storage_unavailable")?;Ok(()) }).await;
            if !keep_directory {
                let _ = std::fs::remove_dir_all(&directory);
            }
            if persisted.is_ok() {
                let _ = done_tx.send(true);
            } // Failed persistence stays unknown to admission.
        });
        Ok(response)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn continuity_read_uses_confirmed_sqlite_session_and_history_without_world_claim() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("chat-continuity-{}", uuid::Uuid::new_v4()));
        files::directory(&root).unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        db.call(|s| schema(&s.connection)).await.unwrap();
        let service = ChatService::new(db.clone());
        let p = json!({"backend":"codex","scopeID":"ordinary","hostSessionID":"actual-host"});
        assert_eq!(
            service.request("agent_chat_read", &p).await.unwrap(),
            json!({"sessionID":null,"historyCount":0,"freshSession":true})
        );
        db.call(|s|{s.connection.execute("INSERT INTO chat_threads(backend,scope,session,history) VALUES('codex','ordinary','native','[{\"user\":true,\"text\":\"confirmed\"},{\"user\":false,\"text\":\"reply\"}]')",[]).map_err(|_|"storage_unavailable")?;Ok(())}).await.unwrap();
        assert_eq!(
            service.request("agent_chat_read", &p).await.unwrap(),
            json!({"sessionID":"native","historyCount":2,"freshSession":false})
        );
        let other = json!({"backend":"pi","scopeID":"ordinary","hostSessionID":"actual-host"});
        assert_eq!(
            service.request("agent_chat_read", &other).await.unwrap()["freshSession"],
            true
        );
        service.request("agent_chat_reset", &p).await.unwrap();
        assert_eq!(
            service.request("agent_chat_read", &p).await.unwrap()["freshSession"],
            true
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn dsh_native_images_reuse_actor_cancel_reaps_and_eof_blocks_resend() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("chat-dsh-service-{}", uuid::Uuid::new_v4()));
        files::directory(&root).unwrap();
        let mock = root.join("mock-node");
        let entry = root.join("entry.js");
        files::publish(&entry, b"fixture-only").unwrap();
        files::publish(&mock,br##"#!/bin/sh
echo $$ > ../pid
IFS= read -r frame
printf '%s\n' '{"id":1,"result":{"agentCapabilities":{"promptCapabilities":{"image":true}}}}'
IFS= read -r frame
printf '%s\n' '{"id":2,"result":{"sessionId":"native-image-chat"}}'
i=3
while IFS= read -r frame; do
printf '%s\n' "$frame" >> ../frames
case "$frame" in *disconnect*) exit 0;; *stall*) sleep 30; continue;; esac
printf '%s\n' '{"method":"session/update","params":{"sessionId":"native-image-chat","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"photo reply"}}}}'
printf '{"id":%s,"result":{"stopReason":"end_turn"}}\n' "$i"
i=$((i+1))
done
"##).unwrap();
        std::fs::set_permissions(&mock, std::fs::Permissions::from_mode(0o700)).unwrap();
        let image = root.join("photo.png");
        files::publish(&image, b"\x89PNG\r\n\x1a\nfixture").unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        db.call(|s| schema(&s.connection)).await.unwrap();
        let service = ChatService::new(db.clone());
        let mut p = json!({"backend":"dsh","scopeID":"ordinary-photo","hostSessionID":"host","requestID":"one","input":"look","executable":mock,"dshEntryPoint":entry,"images":[image],"environment":{}});
        async fn finish(service: &ChatService, p: &Value) -> Value {
            tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    let v = service.request("agent_chat_read", p).await.unwrap();
                    if v["state"] != "running" {
                        return v;
                    }
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap()
        }
        service.request("agent_chat_start", &p).await.unwrap();
        assert_eq!(finish(&service, &p).await["state"], "completed");
        let slot = service
            .dsh
            .lock()
            .await
            .get("ordinary-photo")
            .unwrap()
            .clone();
        let directory = slot.lock().await.as_ref().unwrap().directory.clone();
        let pid = std::fs::read_to_string(directory.join("pid"))
            .unwrap()
            .trim()
            .parse::<i32>()
            .unwrap();
        let frames = std::fs::read_to_string(directory.join("frames")).unwrap();
        assert!(frames.contains("iVBOR") && frames.contains("image/png"));
        p["requestID"] = json!("two");
        p["images"] = json!([]);
        p["input"] = json!("continue");
        service.request("agent_chat_start", &p).await.unwrap();
        assert_eq!(finish(&service, &p).await["sessionID"], "native-image-chat");
        assert_eq!(slot.lock().await.as_ref().unwrap().directory, directory);
        assert_eq!(
            std::fs::read_to_string(directory.join("pid"))
                .unwrap()
                .trim(),
            pid.to_string()
        );
        let before = db
            .call(|s| {
                s.connection
                    .query_row(
                        "SELECT history FROM chat_threads WHERE backend='dsh'",
                        [],
                        |r| r.get::<_, String>(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        p["requestID"] = json!("three");
        p["input"] = json!("stall");
        service.request("agent_chat_start", &p).await.unwrap();
        tokio::time::timeout(
            Duration::from_secs(5),
            service.request("agent_chat_cancel", &p),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(finish(&service, &p).await["state"], "cancelled");
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        let after = db
            .call(|s| {
                s.connection
                    .query_row(
                        "SELECT history FROM chat_threads WHERE backend='dsh'",
                        [],
                        |r| r.get::<_, String>(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(before, after);
        p["requestID"] = json!("four");
        p["input"] = json!("disconnect");
        service.request("agent_chat_start", &p).await.unwrap();
        assert_eq!(finish(&service, &p).await["state"], "unknown");
        p["requestID"] = json!("five");
        assert_eq!(
            service.request("agent_chat_start", &p).await.unwrap_err(),
            "agent_chat_unknown"
        );
        service.request("agent_chat_reset", &p).await.unwrap();
        std::fs::remove_dir_all(root).unwrap();
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn real_mock_process_commits_once_and_cancel_preserves_history() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("chat-test-{}", uuid::Uuid::new_v4()));
        files::directory(&root).unwrap();
        let mock = root.join("mock");
        files::publish(&mock,b"#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"native-one\"}' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"hello\"}}'\n").unwrap();
        std::fs::set_permissions(&mock, std::fs::Permissions::from_mode(0o700)).unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        db.call(|s| schema(&s.connection)).await.unwrap();
        let service = ChatService::new(db.clone());
        let mut p = json!({"backend":"codex","scopeID":"ordinary","hostSessionID":"host","requestID":"first","input":"hi","executable":mock,"environment":{"PATH":"/usr/bin:/bin"}});
        service.request("agent_chat_start", &p).await.unwrap();
        let finish = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let state = service.request("agent_chat_read", &p).await.unwrap();
                if state["state"] != "running" {
                    break state;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(finish["state"], "completed");
        assert_eq!(finish["reply"], "hello");
        assert_eq!(finish["sessionID"], "native-one");
        assert_eq!(
            service.request("agent_chat_start", &p).await.unwrap()["state"],
            "completed"
        );
        let before = db
            .call(|s| {
                s.connection
                    .query_row(
                        "SELECT history FROM chat_threads WHERE backend='codex'",
                        [],
                        |r| r.get::<_, String>(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        files::publish(&mock, b"#!/bin/sh\ncat >/dev/null\nsleep 30\n").unwrap();
        std::fs::set_permissions(&mock, std::fs::Permissions::from_mode(0o700)).unwrap();
        p["requestID"] = json!("second");
        service.request("agent_chat_start", &p).await.unwrap();
        tokio::time::timeout(
            Duration::from_secs(5),
            service.request("agent_chat_cancel", &p),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(
            service.request("agent_chat_read", &p).await.unwrap()["state"],
            "cancelled"
        );
        let after = db
            .call(|s| {
                s.connection
                    .query_row(
                        "SELECT history FROM chat_threads WHERE backend='codex'",
                        [],
                        |r| r.get::<_, String>(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(before, after);
        let mut stale = p.clone();
        stale["hostSessionID"] = json!("other");
        assert_eq!(
            service
                .request("agent_chat_read", &stale)
                .await
                .unwrap_err(),
            "agent_chat_stale_session"
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn startup_does_not_replay_and_history_is_backend_scoped() {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        c.execute(
            "INSERT INTO chat_requests VALUES('codex','s','r','h','d','running',NULL,NULL,NULL)",
            [],
        )
        .unwrap();
        c.execute(
            "INSERT INTO chat_threads(backend,scope,session) VALUES('pi','s','pi-session')",
            [],
        )
        .unwrap();
        recover(&c).unwrap();
        assert_eq!(
            c.query_row("SELECT state FROM chat_requests", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "unknown"
        );
        assert_eq!(
            c.query_row("SELECT session FROM chat_threads", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "pi-session"
        );
    }
    #[test]
    fn native_import_rejects_argument_shaped_ids() {
        assert!(!native("--dangerous"));
        assert!(!native("a b"));
        assert!(native("native-session"));
    }
}
