//! Runtime adapter: trusted business identity -> durable ledger -> host transport.
use crate::{agent_tools, store::Database};
use gmgn_agent_runtime::{
    HostToolContext, HostToolExecutor, HostToolReceipt, HostToolStatus, TurnIdentity,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{future::Future, pin::Pin, sync::Arc};
type FutureResult<T> = Pin<Box<dyn Future<Output = Result<T, String>> + Send + 'static>>;

/// Implementations derive stable IDs from host-owned business/task state.
/// Never return an ID supplied by model arguments or the model's callID.
pub trait BusinessOperationResolver: Send + Sync + 'static {
    fn resolve(
        &self,
        identity: &TurnIdentity,
        tool: &str,
        arguments: &Value,
    ) -> Result<String, String>;
    /// Trusted host may asynchronously approve this exact proposed call. Approval
    /// itself is not a world dispatch and must not perform the requested effect.
    fn resolve_context(&self, context: HostToolContext) -> FutureResult<String> {
        let result = self.resolve(
            &context.identity,
            &context.execution.call.tool_name,
            &context.execution.call.input,
        );
        Box::pin(async move { result })
    }
}
/// Only this transport performs the side effect. It must not retry dispatch itself.
pub trait HostToolTransport: Send + Sync + 'static {
    fn dispatch(
        &self,
        context: HostToolContext,
        operation_id: String,
    ) -> FutureResult<HostToolReceipt>;
}
pub struct LedgerHostTools {
    db: Database,
    resolver: Arc<dyn BusinessOperationResolver>,
    transport: Arc<dyn HostToolTransport>,
}
fn identity_params(i: &TurnIdentity) -> Value {
    json!({"worldID":i.world_id,"residentScope":i.scope_id,"runID":i.run_id,"hostSessionID":i.session_id})
}
impl LedgerHostTools {
    pub fn new(
        db: Database,
        resolver: Arc<dyn BusinessOperationResolver>,
        transport: Arc<dyn HostToolTransport>,
    ) -> Self {
        Self {
            db,
            resolver,
            transport,
        }
    }
    /// Called with trusted host tool definitions, outside the model tool interface.
    pub async fn register(&self, identity: &TurnIdentity, tools: Value) -> Result<(), String> {
        let mut p = identity_params(identity);
        p["tools"] = tools;
        self.db
            .call(move |s| agent_tools::register_authorization(&mut s.connection, &p))
            .await
            .map_err(str::to_owned)?;
        Ok(())
    }
}
struct PendingDispatch {
    db: Database,
    p: Value,
    settled: bool,
}
impl PendingDispatch {
    async fn unknown(&mut self) -> Result<(), String> {
        let p = self.p.clone();
        self.db
            .call(move |s| agent_tools::mark_unknown(&s.connection, &p))
            .await
            .map_err(str::to_owned)?;
        self.settled = true;
        Ok(())
    }
}
impl Drop for PendingDispatch {
    fn drop(&mut self) {
        if self.settled {
            return;
        }
        let db = self.db.clone();
        let p = self.p.clone();
        // Shutdown recovery also changes every remaining inflight record to unknown.
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                let _ = db
                    .call(move |s| agent_tools::mark_unknown(&s.connection, &p))
                    .await;
            });
        }
    }
}
impl HostToolExecutor for LedgerHostTools {
    fn execute(&self, context: HostToolContext) -> FutureResult<HostToolReceipt> {
        let db = self.db.clone();
        let resolver = self.resolver.clone();
        let transport = self.transport.clone();
        Box::pin(async move {
            if context.execution.cancellation.is_cancelled() {
                return Err("host_tool_cancelled".into());
            }
            let cancellation = context.execution.cancellation.clone();
            let proposal = HostToolContext {
                identity: context.identity.clone(),
                execution: context.execution.clone(),
            };
            let operation = tokio::select! {
                _=cancellation.cancelled()=>return Err("host_tool_authorization_cancelled".into()),
                result=resolver.resolve_context(proposal)=>result.map_err(|_|"host_operation_unavailable".to_owned())?,
            };
            if cancellation.is_cancelled() {
                return Err("host_tool_authorization_cancelled".into());
            }
            let call = &context.execution.call;
            let mut p = identity_params(&context.identity);
            p["callID"] = json!(call.tool_call_id);
            p["operationID"] = json!(operation);
            p["toolName"] = json!(call.tool_name);
            p["arguments"] = call.input.clone();
            let authorize = p.clone();
            db.call(move |s| agent_tools::authorize_operation(&mut s.connection, &authorize))
                .await
                .map_err(str::to_owned)?;
            if cancellation.is_cancelled() {
                return Err("host_tool_authorization_cancelled".into());
            }
            // Arm only when begin can persist an execution. Cancelling proposal
            // approval must never create an inflight/unknown execution record.
            let mut pending = PendingDispatch {
                db: db.clone(),
                p: p.clone(),
                settled: false,
            };
            let begin = p.clone();
            let result = db
                .call(move |s| agent_tools::request(&mut s.connection, "agent_tool_begin", &begin))
                .await
                .map_err(str::to_owned)?;
            if result["dispatch"] != true {
                pending.settled = true;
                return Err("host_tool_dispatch_already_recorded".into());
            }
            let identity = context.identity.clone();
            let call_id = call.tool_call_id.clone();
            let cancellation = context.execution.cancellation.clone();
            if cancellation.is_cancelled() {
                pending.unknown().await?;
                return Err("host_tool_cancelled".into());
            }
            let receipt = tokio::select! {
                _=cancellation.cancelled()=>{pending.unknown().await?;return Err("host_tool_cancelled".into());},
                receipt=transport.dispatch(context, operation)=>receipt,
            };
            let receipt = match receipt {
                Ok(r) => r,
                Err(_) => {
                    pending.unknown().await?;
                    return Err("host_tool_result_unknown".into());
                }
            };
            if receipt.identity != identity || receipt.call_id != call_id {
                pending.unknown().await?;
                return Err("host_tool_receipt_identity_mismatch".into());
            }
            if cancellation.is_cancelled() {
                pending.unknown().await?;
                return Err("host_tool_result_unknown".into());
            }
            // Three different facts, three different durable states:
            //   * `Completed` — the host ran the call and returned its result
            //     (`finished`, receipt kept);
            //   * `Rejected`  — the host **answered** with its own named refusal
            //     (bad motion id, unavailable prop, refused placement): the effect
            //     did not start. That is a reported outcome, not a lost one, so it
            //     is settled as the terminal `rejected` and the host's own receipt
            //     is returned unchanged so the model can adapt instead of seeing an
            //     opaque "unknown";
            //   * `Unknown`   — the host could not tell. Only this one is durable
            //     `unknown` (never guessed into applied/not_applied).
            let method = match receipt.status {
                HostToolStatus::Completed => "agent_tool_finish",
                HostToolStatus::Rejected => "agent_tool_refuse",
                HostToolStatus::Unknown => {
                    pending.unknown().await?;
                    return Err("host_tool_result_unknown".into());
                }
            };
            p["receipt"] = match persisted_receipt(&receipt) {
                Ok(value) => value,
                Err(code) => {
                    pending.unknown().await?;
                    return Err(code);
                }
            };
            db.call(move |s| agent_tools::request(&mut s.connection, method, &p))
                .await
                .map_err(str::to_owned)?;
            pending.settled = true;
            Ok(receipt)
        })
    }
}

fn persisted_receipt(receipt: &HostToolReceipt) -> Result<Value, String> {
    if receipt.images.len() > 4 {
        return Err("host_tool_image_limit".into());
    }
    let mut total = 0usize;
    let mut images = Vec::new();
    for image in &receipt.images {
        total = total
            .checked_add(image.bytes.len())
            .ok_or("host_tool_image_limit")?;
        if total > 4 * 1024 * 1024 || image.bytes.is_empty() {
            return Err("host_tool_image_limit".into());
        }
        let valid = match image.media_type.as_str() {
            "image/png" => image.bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            "image/jpeg" => image.bytes.starts_with(b"\xff\xd8\xff"),
            "image/gif" => image.bytes.starts_with(b"GIF87a") || image.bytes.starts_with(b"GIF89a"),
            "image/webp" => {
                image.bytes.starts_with(b"RIFF") && image.bytes.get(8..12) == Some(b"WEBP")
            }
            _ => false,
        };
        if !valid {
            return Err("host_tool_image_invalid".into());
        }
        images.push(json!({"sha256":format!("{:x}",Sha256::digest(&image.bytes)),"mediaType":image.media_type,"length":image.bytes.len()}));
    }
    Ok(json!({"status":"completed","output":receipt.output,"images":images}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use gmgn_agent_runtime::{CancellationToken, ImageInput, ToolCall, ToolExecutionContext};
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct Resolver;
    impl BusinessOperationResolver for Resolver {
        fn resolve(&self, _: &TurnIdentity, _: &str, _: &Value) -> Result<String, String> {
            Ok("trusted-task-operation".into())
        }
    }
    struct Transport {
        db: Database,
        count: Arc<AtomicUsize>,
        mode: u8,
    }
    impl HostToolTransport for Transport {
        fn dispatch(
            &self,
            c: HostToolContext,
            operation_id: String,
        ) -> FutureResult<HostToolReceipt> {
            let db = self.db.clone();
            let count = self.count.clone();
            let mode = self.mode;
            Box::pin(async move {
                assert_eq!(operation_id, "trusted-task-operation");
                let p = identity_params(&c.identity);
                db.call(move|s| {
                    let state:String=s.connection.query_row("SELECT state FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3",rusqlite::params![p["worldID"].as_str(),p["residentScope"].as_str(),p["runID"].as_str()],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                    if state!="inflight" {return Err("test_dispatch_not_persisted");}Ok(())
                }).await.map_err(str::to_owned)?;
                count.fetch_add(1, Ordering::SeqCst);
                if mode == 1 {
                    return Err("private transport diagnostic must not escape".into());
                }
                if mode == 3 {
                    std::future::pending::<()>().await;
                }
                let mut identity = c.identity;
                if mode == 5 {
                    identity.session_id = "wrong-session".into();
                }
                Ok(HostToolReceipt {
                    identity,
                    call_id: if mode == 2 {
                        "wrong".into()
                    } else {
                        c.execution.call.tool_call_id
                    },
                    status: if mode == 4 {
                        HostToolStatus::Unknown
                    } else {
                        HostToolStatus::Completed
                    },
                    output: json!({"ok":true}),
                    images: vec![],
                })
            })
        }
    }
    fn context(call: &str, token: CancellationToken) -> HostToolContext {
        HostToolContext {
            identity: TurnIdentity {
                world_id: "w".into(),
                scope_id: "s".into(),
                session_id: "h".into(),
                run_id: "r".into(),
            },
            execution: ToolExecutionContext {
                call: ToolCall {
                    tool_call_id: call.into(),
                    tool_name: "move".into(),
                    input: json!({"target":"chair"}),
                    provider_executed: None,
                    dynamic: None,
                    thought_signature: None,
                },
                cancellation: token,
            },
        }
    }
    async fn setup(mode: u8) -> (LedgerHostTools, Arc<AtomicUsize>, std::path::PathBuf) {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-ledger-adapter-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        db.call(|s|{crate::agent_scheduler::schema(&s.connection)?;agent_tools::schema(&s.connection)?;s.connection.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','e','{}','claimed','r','h')",[]).map_err(|_|"storage_unavailable")?;Ok(())}).await.unwrap();
        let count = Arc::new(AtomicUsize::new(0));
        let adapter = LedgerHostTools::new(
            db.clone(),
            Arc::new(Resolver),
            Arc::new(Transport {
                db,
                count: count.clone(),
                mode,
            }),
        );
        adapter.register(&context("c",CancellationToken::new()).identity,json!([{"name":"move","effect":"write","inputSchema":{"type":"object","properties":{"target":{"type":"string"}},"required":["target"]}}])).await.unwrap();
        (adapter, count, root)
    }
    async fn state(a: &LedgerHostTools) -> String {
        a.db.call(|s| {
            s.connection
                .query_row("SELECT state FROM agent_tool_calls LIMIT 1", [], |r| {
                    r.get(0)
                })
                .map_err(|_| "storage_unavailable")
        })
        .await
        .unwrap()
    }
    struct AsyncApproval {
        entered: Arc<AtomicUsize>,
        wait: bool,
    }
    impl BusinessOperationResolver for AsyncApproval {
        fn resolve(&self, _: &TurnIdentity, _: &str, _: &Value) -> Result<String, String> {
            Err("sync resolver must not run".into())
        }
        fn resolve_context(&self, c: HostToolContext) -> FutureResult<String> {
            let entered = self.entered.clone();
            let wait = self.wait;
            Box::pin(async move {
                assert_eq!(c.execution.call.input["target"], "chair");
                entered.fetch_add(1, Ordering::SeqCst);
                if wait {
                    std::future::pending::<()>().await;
                }
                Ok("trusted-task-operation".into())
            })
        }
    }
    #[tokio::test]
    async fn async_host_approval_precedes_ledger_and_dispatch() {
        let (mut a, count, root) = setup(0).await;
        let entered = Arc::new(AtomicUsize::new(0));
        a.resolver = Arc::new(AsyncApproval {
            entered: entered.clone(),
            wait: false,
        });
        assert!(a
            .execute(context("c", CancellationToken::new()))
            .await
            .is_ok());
        assert_eq!(entered.load(Ordering::SeqCst), 1);
        assert_eq!(count.load(Ordering::SeqCst), 1);
        drop(a);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn cancellation_or_abort_during_approval_creates_no_execution() {
        for abort in [false, true] {
            let (mut a, count, root) = setup(0).await;
            let entered = Arc::new(AtomicUsize::new(0));
            a.resolver = Arc::new(AsyncApproval {
                entered: entered.clone(),
                wait: true,
            });
            let token = CancellationToken::new();
            let task = tokio::spawn(a.execute(context("c", token.clone())));
            tokio::time::timeout(std::time::Duration::from_secs(2), async {
                while entered.load(Ordering::SeqCst) == 0 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
            if abort {
                task.abort();
                assert!(task.await.is_err());
            } else {
                token.cancel();
                assert!(
                    matches!(task.await.unwrap(),Err(code) if code=="host_tool_authorization_cancelled")
                );
            }
            let recorded =
                a.db.call(|s| {
                    s.connection
                        .query_row("SELECT COUNT(*) FROM agent_tool_calls", [], |r| {
                            r.get::<_, i64>(0)
                        })
                        .map_err(|_| "storage_unavailable")
                })
                .await
                .unwrap();
            assert_eq!(recorded, 0);
            assert_eq!(count.load(Ordering::SeqCst), 0);
            drop(a);
            std::fs::remove_dir_all(root).unwrap();
        }
    }
    #[tokio::test]
    async fn image_receipt_uses_digest_and_changed_image_conflicts() {
        let (a, _, root) = setup(0).await;
        let mut p = identity_params(&context("c", CancellationToken::new()).identity);
        p["callID"] = json!("c");
        p["operationID"] = json!("trusted-task-operation");
        p["toolName"] = json!("move");
        p["arguments"] = json!({"target":"chair"});
        let begin = p.clone();
        a.db.call(move |s| {
            agent_tools::authorize_operation(&mut s.connection, &begin)?;
            agent_tools::request(&mut s.connection, "agent_tool_begin", &begin)
        })
        .await
        .unwrap();
        let mut bytes = vec![0; 4 * 1024 * 1024];
        bytes[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
        let mut receipt = HostToolReceipt {
            identity: context("c", CancellationToken::new()).identity,
            call_id: "c".into(),
            status: HostToolStatus::Completed,
            output: json!({"ok":true}),
            images: vec![ImageInput {
                bytes,
                media_type: "image/png".into(),
            }],
        };
        p["receipt"] = persisted_receipt(&receipt).unwrap();
        assert!(p["receipt"].to_string().len() < 1024);
        assert_eq!(p["receipt"]["images"][0]["length"], 4 * 1024 * 1024);
        assert!(p["receipt"]["images"][0].get("bytes").is_none());
        let finish = p.clone();
        a.db.call(move |s| agent_tools::request(&mut s.connection, "agent_tool_finish", &finish))
            .await
            .unwrap();
        let repeated = p.clone();
        a.db.call(move |s| agent_tools::request(&mut s.connection, "agent_tool_finish", &repeated))
            .await
            .unwrap();
        receipt.images[0].bytes[8] = 1;
        p["receipt"] = persisted_receipt(&receipt).unwrap();
        assert_eq!(
            a.db.call(move |s| agent_tools::request(&mut s.connection, "agent_tool_finish", &p))
                .await
                .unwrap_err(),
            "agent_tool_receipt_conflict"
        );
        drop(a);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn persisted_before_dispatch_and_duplicate_never_replays() {
        let (a, count, root) = setup(0).await;
        assert!(a
            .execute(context("c", CancellationToken::new()))
            .await
            .is_ok());
        assert!(a
            .execute(context("c", CancellationToken::new()))
            .await
            .is_err());
        assert!(a
            .execute(context("different-model-call", CancellationToken::new()))
            .await
            .is_err());
        assert_eq!(count.load(Ordering::SeqCst), 1);
        assert_eq!(state(&a).await, "finished");
        drop(a);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn disconnect_and_wrong_receipt_are_unknown() {
        for mode in [1, 2, 4, 5] {
            let (a, count, root) = setup(mode).await;
            assert!(a
                .execute(context("c", CancellationToken::new()))
                .await
                .is_err());
            assert_eq!(state(&a).await, "unknown");
            assert!(a
                .execute(context("c2", CancellationToken::new()))
                .await
                .is_err());
            assert_eq!(count.load(Ordering::SeqCst), 1);
            drop(a);
            std::fs::remove_dir_all(root).unwrap();
        }
    }
    #[tokio::test]
    async fn cancelled_dispatch_remains_unknown_across_sqlite_recovery() {
        let (a, count, root) = setup(3).await;
        let a = Arc::new(a);
        let token = CancellationToken::new();
        let fut = a.execute(context("c", token.clone()));
        let task = tokio::spawn(fut);
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while count.load(Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        token.cancel();
        assert!(task.await.unwrap().is_err());
        assert_eq!(state(&a).await, "unknown");
        let db = rusqlite::Connection::open(root.join("tasks.sqlite3")).unwrap();
        agent_tools::recover(&db).unwrap();
        let durable: String = db
            .query_row("SELECT state FROM agent_tool_calls", [], |r| r.get(0))
            .unwrap();
        assert_eq!(durable, "unknown");
        drop(db);
        drop(a);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn dropped_executor_future_marks_unknown() {
        let (a, count, root) = setup(3).await;
        let task = tokio::spawn(a.execute(context("c", CancellationToken::new())));
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while count.load(Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        task.abort();
        let _ = task.await;
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while state(&a).await != "unknown" {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        drop(a);
        std::fs::remove_dir_all(root).unwrap();
    }
}
