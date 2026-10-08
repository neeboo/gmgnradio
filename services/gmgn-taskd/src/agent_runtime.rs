//! Authenticated host-facing Rutis sessions. This module has no model-visible RPCs.
use crate::{
    agent_runtime_tools::{BusinessOperationResolver, HostToolTransport, LedgerHostTools},
    agent_scheduler,
    store::Database,
};
use base64::Engine;
use gmgn_agent_runtime::{
    provider::{build_provider, ProviderConfig},
    HostToolContext, HostToolReceipt, HostToolSchema, HostToolStatus, ImageInput, RuntimeConfig,
    RutisRuntime, TurnIdentity, UserInput,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, future::Future, pin::Pin, sync::Arc, time::Duration};
use tokio::sync::{oneshot, Mutex};

type Result<T> = std::result::Result<T, String>;
fn decode_images(p: &Value) -> Result<Vec<ImageInput>> {
    let Some(value) = p.get("images") else {
        return Ok(vec![]);
    };
    let array = value
        .as_array()
        .filter(|v| v.len() <= 4)
        .ok_or("image_count_limit")?;
    let mut total = 0usize;
    let mut images = Vec::new();
    for image in array {
        let media_type = image["mediaType"]
            .as_str()
            .ok_or("image_format_invalid")?
            .to_owned();
        let encoded = image["base64"]
            .as_str()
            .filter(|v| v.len() <= 6 * 1024 * 1024)
            .ok_or("image_byte_limit")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| "image_format_invalid")?;
        total = total.checked_add(bytes.len()).ok_or("image_byte_limit")?;
        if total > 4 * 1024 * 1024 {
            return Err("image_byte_limit".into());
        }
        images.push(ImageInput { bytes, media_type });
    }
    Ok(images)
}
/// Keep dynamic provider/storage diagnostics out of the authenticated RPC response.
pub fn public_error_code(error: &str) -> &'static str {
    match error {
        "unknown_method" => "unknown_method",
        "agent_runtime_invalid_request" => "agent_runtime_invalid_request",
        "agent_runtime_stale_session" => "agent_runtime_stale_session",
        "agent_runtime_run_not_claimed" => "agent_runtime_run_not_claimed",
        "agent_runtime_not_configured" => "agent_runtime_not_configured",
        "agent_runtime_unsupported_input" => "agent_runtime_unsupported_input",
        "agent_runtime_invalid_tools" => "agent_runtime_invalid_tools",
        "agent_runtime_invalid_operations" => "agent_runtime_invalid_operations",
        "agent_runtime_duplicate_tool" => "agent_runtime_duplicate_tool",
        "agent_runtime_invalid_provider" => "agent_runtime_invalid_provider",
        "unsupported_provider_backend" => "unsupported_provider_backend",
        "invalid_provider_endpoint" => "invalid_provider_endpoint",
        "invalid_provider_model" => "invalid_provider_model",
        "invalid_provider_api_key" => "invalid_provider_api_key",
        "agent_runtime_input_limit" => "agent_runtime_input_limit",
        "agent_runtime_session_exists" => "agent_runtime_session_exists",
        "agent_runtime_session_limit" => "agent_runtime_session_limit",
        "agent_runtime_invalid_input" => "agent_runtime_invalid_input",
        "agent_runtime_already_started" => "agent_runtime_already_started",
        "agent_runtime_receipt_limit" => "agent_runtime_receipt_limit",
        "agent_runtime_receipt_not_pending" => "agent_runtime_receipt_not_pending",
        "agent_runtime_receipt_mismatch" => "agent_runtime_receipt_mismatch",
        "agent_runtime_invalid_receipt" => "agent_runtime_invalid_receipt",
        "agent_runtime_receipt_expired" => "agent_runtime_receipt_expired",
        "agent_runtime_invalid_verification" => "agent_runtime_invalid_verification",
        "agent_runtime_reconciliation_mismatch" => "agent_runtime_reconciliation_mismatch",
        "agent_runtime_authorization_not_pending" => "agent_runtime_authorization_not_pending",
        "agent_runtime_authorization_conflict" => "agent_runtime_authorization_conflict",
        "agent_runtime_invalid_authorization" => "agent_runtime_invalid_authorization",
        "agent_runtime_invalid_steering" => "agent_runtime_invalid_steering",
        "agent_runtime_steering_not_admitted" => "agent_runtime_steering_not_admitted",
        "agent_runtime_steering_conflict" => "agent_runtime_steering_conflict",
        "model_image_input_unsupported" => "model_image_input_unsupported",
        "image_count_limit" => "image_count_limit",
        "image_byte_limit" => "image_byte_limit",
        "image_format_invalid" => "image_format_invalid",
        _ => "agent_runtime_failed",
    }
}
fn text(p: &Value, k: &str) -> Result<String> {
    p[k].as_str()
        .filter(|v| !v.is_empty() && v.len() <= 256)
        .map(str::to_owned)
        .ok_or_else(|| "agent_runtime_invalid_request".into())
}
fn identity(p: &Value) -> Result<TurnIdentity> {
    Ok(TurnIdentity {
        world_id: text(p, "worldID")?,
        scope_id: text(p, "residentScope")?,
        session_id: text(p, "hostSessionID")?,
        run_id: text(p, "runID")?,
    })
}
fn params(i: &TurnIdentity) -> Value {
    json!({"worldID":i.world_id,"residentScope":i.scope_id,"hostSessionID":i.session_id,"runID":i.run_id})
}
fn key(i: &TurnIdentity) -> String {
    format!(
        "{}:{}:{}:{}",
        i.world_id.len(),
        i.world_id,
        i.scope_id.len(),
        i.scope_id
    )
}
#[derive(Clone)]
struct Grant {
    operation: String,
    tool: String,
    args: Value,
}
struct Grants {
    identity: TurnIdentity,
    items: std::sync::Mutex<Vec<Grant>>,
    dynamic: Option<Arc<Queue>>,
}
impl BusinessOperationResolver for Grants {
    fn resolve(&self, i: &TurnIdentity, t: &str, a: &Value) -> Result<String> {
        if i != &self.identity {
            return Err("agent_runtime_stale_session".into());
        }
        self.items
            .lock()
            .unwrap()
            .iter()
            .find(|g| g.tool == t && g.args == *a)
            .map(|g| g.operation.clone())
            .ok_or_else(|| "agent_runtime_operation_not_granted".into())
    }
    fn resolve_context(
        &self,
        c: HostToolContext,
    ) -> Pin<Box<dyn Future<Output = Result<String>> + Send + 'static>> {
        let fixed = self.resolve(
            &c.identity,
            &c.execution.call.tool_name,
            &c.execution.call.input,
        );
        let queue = self.dynamic.clone();
        let matches = c.identity == self.identity;
        Box::pin(async move {
            if let Ok(operation) = fixed {
                return Ok(operation);
            }
            if !matches {
                return Err("agent_runtime_stale_session".into());
            }
            let q = queue.ok_or("agent_runtime_operation_not_granted")?;
            if c.execution.call.input.to_string().len() > 16384 {
                return Err("agent_runtime_input_limit".into());
            }
            let call = c.execution.call.tool_call_id.clone();
            let mut request = params(&c.identity);
            request["phase"] = json!("authorize");
            request["callID"] = json!(call);
            request["toolName"] = json!(c.execution.call.tool_name);
            request["arguments"] = c.execution.call.input;
            let (tx, rx) = oneshot::channel();
            {
                let mut proposals = q.authorization.lock().await;
                if proposals.len() >= 32
                    || proposals.contains_key(&call)
                    || q.authorization_answers.lock().await.len() >= 128
                {
                    return Err("agent_runtime_queue_limit".into());
                }
                proposals.insert(call.clone(), Proposal { request, tx });
            }
            let _cleanup = AuthorizationCleanup {
                queue: q.clone(),
                call: call.clone(),
            };
            let result = tokio::select! {biased;_=c.execution.cancellation.cancelled()=>Err("agent_runtime_cancelled".into()),r=tokio::time::timeout(Duration::from_secs(120),rx)=>match r{Ok(Ok(v))=>v,_=>Err("agent_runtime_authorization_timeout".into())}};
            q.authorization.lock().await.remove(&call);
            result
        })
    }
}
struct Proposal {
    request: Value,
    tx: oneshot::Sender<Result<String>>,
}
struct Pending {
    request: Value,
    tx: oneshot::Sender<HostToolReceipt>,
}
#[derive(Default)]
struct Queue {
    pending: Mutex<HashMap<String, Pending>>,
    authorization: Mutex<HashMap<String, Proposal>>,
    authorization_answers: Mutex<HashMap<String, Value>>,
    execution_answers: Mutex<HashMap<String, Value>>,
}
struct AuthorizationCleanup {
    queue: Arc<Queue>,
    call: String,
}
impl Drop for AuthorizationCleanup {
    fn drop(&mut self) {
        let queue = self.queue.clone();
        let call = self.call.clone();
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                queue.authorization.lock().await.remove(&call);
            });
        }
    }
}
struct Transport(Arc<Queue>);
struct QueueCleanup {
    queue: Arc<Queue>,
    call: String,
}
impl Drop for QueueCleanup {
    fn drop(&mut self) {
        let queue = self.queue.clone();
        let call = self.call.clone();
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                queue.pending.lock().await.remove(&call);
            });
        }
    }
}
impl HostToolTransport for Transport {
    fn dispatch(
        &self,
        c: HostToolContext,
        op: String,
    ) -> Pin<Box<dyn Future<Output = Result<HostToolReceipt>> + Send + 'static>> {
        let q = self.0.clone();
        Box::pin(async move {
            let id = c.execution.call.tool_call_id.clone();
            let mut request = params(&c.identity);
            request["callID"] = json!(id);
            request["phase"] = json!("execute");
            request["operationID"] = json!(op);
            request["toolName"] = json!(c.execution.call.tool_name);
            request["arguments"] = c.execution.call.input;
            let (tx, rx) = oneshot::channel();
            {
                let mut pending = q.pending.lock().await;
                if pending.len() >= 32 || pending.contains_key(&id) {
                    return Err("agent_runtime_queue_limit".into());
                }
                pending.insert(id.clone(), Pending { request, tx });
            }
            let _cleanup = QueueCleanup {
                queue: q.clone(),
                call: id.clone(),
            };
            let result = tokio::select! {_=c.execution.cancellation.cancelled()=>Err("agent_runtime_cancelled".into()),r=tokio::time::timeout(Duration::from_secs(120),rx)=>match r{Ok(Ok(v))=>Ok(v),_=>Err("agent_runtime_receipt_timeout".into())}};
            q.pending.lock().await.remove(&id);
            result
        })
    }
}
struct Session {
    identity: TurnIdentity,
    event: String,
    runtime: Arc<RutisRuntime>,
    queue: Arc<Queue>,
    state: Mutex<String>,
    text: Mutex<String>,
    cancellation: gmgn_agent_runtime::CancellationToken,
    grants: Arc<Grants>,
    steering_answers: Mutex<HashMap<String, Value>>,
}
pub struct RuntimeService {
    db: Database,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use gmgn_agent_runtime::{LlmResponse, ScriptedLlm, ToolCall};
    async fn setup() -> (RuntimeService, Value, std::path::PathBuf) {
        setup_dynamic(false).await
    }
    async fn setup_dynamic(dynamic: bool) -> (RuntimeService, Value, std::path::PathBuf) {
        setup_options(dynamic, false).await
    }
    async fn setup_options(
        dynamic: bool,
        vision: bool,
    ) -> (RuntimeService, Value, std::path::PathBuf) {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-runtime-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        let i = TurnIdentity {
            world_id: "w".into(),
            scope_id: "s".into(),
            session_id: "h".into(),
            run_id: "r".into(),
        };
        let mut p = params(&i);
        p["eventID"] = json!("e");
        db.call(|s|{agent_scheduler::request(&mut s.connection,"agent_loop_configure",&json!({"worldID":"w","residentScope":"s","hostSessionID":"h","hourlyLimit":6,"minimumWakeIntervalSeconds":1}))?;s.connection.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','e','{}','claimed','r','h')",[]).map_err(|_|"storage_unavailable")?;Ok(())}).await.unwrap();
        let queue = Arc::new(Queue::default());
        let schema = json!({"type":"object","properties":{"target":{"type":"string"}},"required":["target"]});
        let grants = Arc::new(Grants {
            identity: i.clone(),
            dynamic: dynamic.then(|| queue.clone()),
            items: std::sync::Mutex::new(if dynamic {
                vec![]
            } else {
                vec![Grant {
                    operation: "trusted-op".into(),
                    tool: "move".into(),
                    args: json!({"target":"chair"}),
                }]
            }),
        });
        let tools = Arc::new(LedgerHostTools::new(
            db.clone(),
            grants.clone(),
            Arc::new(Transport(queue.clone())),
        ));
        tools
            .register(
                &i,
                json!([{"name":"move","effect":"write","inputSchema":schema}]),
            )
            .await
            .unwrap();
        let model = Arc::new(ScriptedLlm::new(vec![
            LlmResponse::tool_calls(vec![ToolCall {
                tool_call_id: "c".into(),
                tool_name: "move".into(),
                input: json!({"target":"chair"}),
                provider_executed: None,
                dynamic: None,
                thought_signature: None,
            }]),
            LlmResponse::content("done"),
        ]));
        let runtime = Arc::new(
            RutisRuntime::new_host(
                model,
                vec![HostToolSchema {
                    name: "move".into(),
                    description: "move".into(),
                    parameters: schema,
                }],
                tools,
                RuntimeConfig {
                    allowed_tools: ["move".to_owned()].into_iter().collect(),
                    supports_images: vision,
                    ..Default::default()
                },
            )
            .await
            .unwrap(),
        );
        let service = RuntimeService::new(db);
        service.sessions.lock().await.insert(
            key(&i),
            Arc::new(Session {
                identity: i,
                event: "e".into(),
                runtime,
                queue,
                state: Mutex::new("configured".into()),
                text: Mutex::new(String::new()),
                cancellation: gmgn_agent_runtime::CancellationToken::new(),
                grants,
                steering_answers: Mutex::new(HashMap::new()),
            }),
        );
        (service, p, root)
    }
    async fn wait(service: &RuntimeService, p: &Value, pending: bool) -> Value {
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let v = service.request("agent_runtime_read", p).await.unwrap();
                if pending && !v["pendingTools"].as_array().unwrap().is_empty()
                    || !pending
                        && ["completed", "failed", "unknown", "cancelled"]
                            .contains(&v["state"].as_str().unwrap())
                {
                    return v;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap()
    }
    #[tokio::test]
    async fn admitted_steering_is_identity_bound_and_exactly_once() {
        let (service, mut p, root) = setup().await;
        p["input"] = json!("move");
        service.request("agent_runtime_start", &p).await.unwrap();
        wait(&service, &p, true).await;
        let mut steer = p.clone();
        steer["messageID"] = json!("guide-1");
        steer["input"] = json!("change target");
        steer["inputRef"] = json!({"submissionID":"guide-1","inputSHA256":format!("{:x}",Sha256::digest(b"change target")),"imageReferences":[]});
        steer["operations"] = json!([{"operationID":"new-business-operation","toolName":"move","arguments":{"target":"new-chair"}}]);
        assert!(service
            .request("agent_runtime_steer", &steer)
            .await
            .is_err());
        let admission = steer.clone();
        service
            .db
            .call(move |s| {
                agent_scheduler::request(&mut s.connection, "agent_loop_steer_admit", &admission)
            })
            .await
            .unwrap();
        let delivered = service
            .request("agent_runtime_steer", &steer)
            .await
            .unwrap();
        assert_eq!(delivered["delivery"], "delivered");
        assert_eq!(delivered["grantsApplied"], true);
        assert_eq!(
            service
                .request("agent_runtime_steer", &steer)
                .await
                .unwrap()["duplicate"],
            true
        );
        let mut changed = steer.clone();
        changed["operations"][0]["operationID"] = json!("changed-op");
        assert!(service
            .request("agent_runtime_steer", &changed)
            .await
            .is_err());
        let session = service.session(&identity(&p).unwrap()).await.unwrap();
        assert_eq!(session.grants.items.lock().unwrap().len(), 2);
        service.request("agent_runtime_cancel", &p).await.unwrap();
        assert_eq!(wait(&service, &p, false).await["state"], "unknown");
        drop(session);
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn typed_user_and_tool_images_reach_real_runtime_and_receipt_duplicates_match() {
        let (service, mut p, root) = setup_options(false, true).await;
        let image = json!({"mediaType":"image/png","base64":base64::engine::general_purpose::STANDARD.encode(b"\x89PNG\r\n\x1a\n")});
        p["input"] = json!("move using image");
        p["images"] = json!([image]);
        service.request("agent_runtime_start", &p).await.unwrap();
        let pending = wait(&service, &p, true).await["pendingTools"][0].clone();
        let mut receipt = pending;
        receipt["status"] = json!("completed");
        receipt["output"] = json!({"ok":true});
        receipt["images"] = p["images"].clone();
        service
            .request("agent_runtime_tool_receipt", &receipt)
            .await
            .unwrap();
        assert_eq!(
            service
                .request("agent_runtime_tool_receipt", &receipt)
                .await
                .unwrap()["duplicate"],
            true
        );
        let mut changed = receipt.clone();
        changed["images"][0]["base64"] =
            json!(base64::engine::general_purpose::STANDARD.encode(b"\x89PNG\r\n\x1a\nchanged"));
        assert!(service
            .request("agent_runtime_tool_receipt", &changed)
            .await
            .is_err());
        assert_eq!(wait(&service, &p, false).await["state"], "completed");
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn dynamic_authorization_precedes_durable_dispatch_and_binds_arguments() {
        let (service, mut p, root) = setup_dynamic(true).await;
        p["input"] = json!("move");
        service.request("agent_runtime_start", &p).await.unwrap();
        let proposal = wait(&service, &p, true).await["pendingTools"][0].clone();
        assert_eq!(proposal["phase"], "authorize");
        assert!(proposal.get("operationID").is_none());
        let count: i64 = service
            .db
            .call(|s| {
                s.connection
                    .query_row("SELECT count(*) FROM agent_tool_calls", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(count, 0);
        let mut approval = proposal.clone();
        approval["decision"] = json!("approved");
        approval["operationID"] = json!("host-business-operation");
        let mut wrong = approval.clone();
        wrong["arguments"] = json!({"target":"other"});
        assert!(service
            .request("agent_runtime_authorize", &wrong)
            .await
            .is_err());
        service
            .request("agent_runtime_authorize", &approval)
            .await
            .unwrap();
        assert_eq!(
            service
                .request("agent_runtime_authorize", &approval)
                .await
                .unwrap()["duplicate"],
            true
        );
        wrong = approval.clone();
        wrong["operationID"] = json!("other-op");
        assert!(service
            .request("agent_runtime_authorize", &wrong)
            .await
            .is_err());
        let execute = wait(&service, &p, true).await["pendingTools"][0].clone();
        assert_eq!(execute["phase"], "execute");
        assert_eq!(execute["operationID"], "host-business-operation");
        let state: String = service
            .db
            .call(|s| {
                s.connection
                    .query_row(
                        "SELECT state FROM agent_tool_calls WHERE call='c'",
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(state, "inflight");
        let mut receipt = execute;
        receipt["status"] = json!("completed");
        receipt["output"] = json!({"ok":true});
        service
            .request("agent_runtime_tool_receipt", &receipt)
            .await
            .unwrap();
        assert_eq!(wait(&service, &p, false).await["state"], "completed");
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn cancellation_during_authorization_never_dispatches() {
        let (service, mut p, root) = setup_dynamic(true).await;
        p["input"] = json!("move");
        service.request("agent_runtime_start", &p).await.unwrap();
        assert_eq!(
            wait(&service, &p, true).await["pendingTools"][0]["phase"],
            "authorize"
        );
        service.request("agent_runtime_cancel", &p).await.unwrap();
        assert_eq!(wait(&service, &p, false).await["state"], "cancelled");
        let count: i64 = service
            .db
            .call(|s| {
                s.connection
                    .query_row("SELECT count(*) FROM agent_tool_calls", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(count, 0);
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn sqlite_tool_receipt_continues_real_rutis_loop() {
        let (service, mut p, root) = setup().await;
        p["input"] = json!("move");
        let mut unsupported = p.clone();
        unsupported["attachments"] = json!(["image.png"]);
        assert_eq!(
            service
                .request("agent_runtime_start", &unsupported)
                .await
                .unwrap_err(),
            "agent_runtime_unsupported_input"
        );
        service.request("agent_runtime_start", &p).await.unwrap();
        let v = wait(&service, &p, true).await;
        assert_eq!(v["pendingTools"][0]["operationID"], "trusted-op");
        assert_eq!(v["state"], "running");
        let mut receipt = p.clone();
        receipt["callID"] = json!("c");
        receipt["operationID"] = json!("wrong");
        receipt["status"] = json!("completed");
        receipt["output"] = json!({"ok":true});
        assert!(service
            .request("agent_runtime_tool_receipt", &receipt)
            .await
            .is_err());
        receipt["operationID"] = json!("trusted-op");
        let mut wrong = receipt.clone();
        wrong["hostSessionID"] = json!("other");
        assert!(service
            .request("agent_runtime_tool_receipt", &wrong)
            .await
            .is_err());
        service
            .request("agent_runtime_tool_receipt", &receipt)
            .await
            .unwrap();
        assert_eq!(
            service
                .request("agent_runtime_tool_receipt", &receipt)
                .await
                .unwrap()["duplicate"],
            true
        );
        let completed = wait(&service, &p, false).await;
        assert_eq!(completed["state"], "completed");
        assert_eq!(completed["text"], "done");
        assert!(service.request("agent_runtime_start", &p).await.is_err());
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn cancel_before_start_confirms_no_execution_and_rejects_start() {
        let (service, mut p, root) = setup().await;
        let v = service.request("agent_runtime_cancel", &p).await.unwrap();
        assert_eq!(v["state"], "cancelled");
        p["input"] = json!("move");
        assert!(service.request("agent_runtime_start", &p).await.is_err());
        let v = service
            .db
            .call(|s| {
                agent_scheduler::request(
                    &mut s.connection,
                    "agent_loop_read",
                    &json!({"worldID":"w","residentScope":"s"}),
                )
            })
            .await
            .unwrap();
        assert_eq!(v["events"][0]["state"], "cancelled");
        let n: i64 = service
            .db
            .call(|s| {
                s.connection
                    .query_row("SELECT count(*) FROM agent_tool_calls", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(n, 0);
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn restart_reconciliation_binds_both_sessions_and_every_unknown_operation() {
        let (service, mut p, root) = setup().await;
        p["input"] = json!("move");
        service.request("agent_runtime_start", &p).await.unwrap();
        wait(&service, &p, true).await;
        service.request("agent_runtime_cancel", &p).await.unwrap();
        assert_eq!(wait(&service, &p, false).await["state"], "unknown");
        service.db.call(|store| {
            store.connection.execute("INSERT INTO agent_tool_calls(world,scope,run,session,call,operation,tool,input,effect,state,receipt) SELECT world,scope,run,session,'c2','trusted-op-2',tool,input,effect,'unknown',NULL FROM agent_tool_calls WHERE call='c'",[]).map_err(|_|"storage_unavailable")?;
            agent_scheduler::request(&mut store.connection,"agent_loop_configure",&json!({"worldID":"w","residentScope":"s","hostSessionID":"h2","hourlyLimit":6,"minimumWakeIntervalSeconds":1}))?;
            Ok(())
        }).await.unwrap();
        // The recovery service has no in-memory session. SQLite is authoritative.
        let recovered = RuntimeService::new(Database::open(root.clone(), None).unwrap());
        let mut verification = json!({"worldID":"w","residentScope":"s","hostSessionID":"h2","originalHostSessionID":"h","runID":"r","eventID":"e","callID":"c","operationID":"trusted-op","outcome":"not_applied"});
        fn bind(p: &mut Value) {
            let mut receipt = p.clone();
            receipt["kind"] = json!("host_state_verification");
            receipt["verifiedAtMillis"] = json!(123);
            receipt["observedState"] = json!({"objectPosition":"unchanged"});
            p["verificationReceipt"] = receipt;
        }
        bind(&mut verification);
        for (field, value) in [
            ("hostSessionID", "old"),
            ("originalHostSessionID", "wrong"),
            ("operationID", "wrong"),
        ] {
            let mut wrong = verification.clone();
            wrong.as_object_mut().unwrap().remove("verificationReceipt");
            wrong[field] = json!(value);
            bind(&mut wrong);
            assert!(recovered
                .request("agent_runtime_reconcile", &wrong)
                .await
                .is_err());
        }
        let untouched: i64 = recovered
            .db
            .call(|store| {
                store
                    .connection
                    .query_row(
                        "SELECT count(*) FROM agent_tool_calls WHERE state='unknown'",
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(untouched, 2);
        let first = recovered
            .request("agent_runtime_reconcile", &verification)
            .await
            .unwrap();
        assert_eq!(first["runReleased"], false);
        assert_eq!(first["remainingUnknownTools"], 1);
        verification
            .as_object_mut()
            .unwrap()
            .remove("verificationReceipt");
        verification["callID"] = json!("c2");
        verification["operationID"] = json!("trusted-op-2");
        verification["outcome"] = json!("applied");
        bind(&mut verification);
        let last = recovered
            .request("agent_runtime_reconcile", &verification)
            .await
            .unwrap();
        assert_eq!(last["runReleased"], true);
        let duplicate = recovered
            .request("agent_runtime_reconcile", &verification)
            .await
            .unwrap();
        assert_eq!(duplicate["duplicate"], true);
        assert_eq!(duplicate["runReleased"], true);
        let mut changed = verification.clone();
        changed["verificationReceipt"]["observedState"] = json!({"objectPosition":"different"});
        assert!(recovered
            .request("agent_runtime_reconcile", &changed)
            .await
            .is_err());
        let (event, calls): (String, i64) = recovered
            .db
            .call(|store| {
                let event = store
                    .connection
                    .query_row(
                        "SELECT state FROM agent_loop_events WHERE event='e'",
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")?;
                let calls = store
                    .connection
                    .query_row("SELECT count(*) FROM agent_tool_calls", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")?;
                Ok((event, calls))
            })
            .await
            .unwrap();
        assert_eq!(event, "failed");
        assert_eq!(calls, 2); // No new dispatch or retry.
        drop(recovered);
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn cancellation_of_dispatched_tool_remains_unknown() {
        let (service, mut p, root) = setup().await;
        p["input"] = json!("move");
        service.request("agent_runtime_start", &p).await.unwrap();
        wait(&service, &p, true).await;
        service.request("agent_runtime_cancel", &p).await.unwrap();
        assert_eq!(wait(&service, &p, false).await["state"], "unknown");
        let v = service
            .db
            .call(|s| {
                agent_scheduler::request(
                    &mut s.connection,
                    "agent_loop_read",
                    &json!({"worldID":"w","residentScope":"s"}),
                )
            })
            .await
            .unwrap();
        assert_eq!(v["events"][0]["state"], "unknown");
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
}
impl RuntimeService {
    pub fn new(db: Database) -> Self {
        Self {
            db,
            sessions: Mutex::new(HashMap::new()),
        }
    }
    async fn claimed(&self, i: &TurnIdentity, event: &str) -> Result<()> {
        let p = params(i);
        let event = event.to_owned();
        self.db
            .call(move |s| {
                let v = agent_scheduler::request(&mut s.connection, "agent_loop_read", &p)?;
                if v["config"]["hostSessionID"] != p["hostSessionID"] {
                    return Err("agent_runtime_stale_session");
                }
                if !v["events"].as_array().unwrap().iter().any(|e| {
                    e["eventID"] == event
                        && e["runID"] == p["runID"]
                        && e["hostSessionID"] == p["hostSessionID"]
                        && e["state"] == "claimed"
                }) {
                    return Err("agent_runtime_run_not_claimed");
                }
                Ok(())
            })
            .await
            .map_err(str::to_owned)
    }
    async fn session(&self, i: &TurnIdentity) -> Result<Arc<Session>> {
        let s = self
            .sessions
            .lock()
            .await
            .get(&key(i))
            .cloned()
            .ok_or("agent_runtime_not_configured")?;
        if s.identity != *i {
            return Err("agent_runtime_stale_session".into());
        }
        let p = params(i);
        self.db
            .call(move |store| {
                let v = agent_scheduler::request(&mut store.connection, "agent_loop_read", &p)?;
                if v["config"]["hostSessionID"] != p["hostSessionID"] {
                    return Err("agent_runtime_stale_session");
                }
                Ok(())
            })
            .await
            .map_err(str::to_owned)?;
        Ok(s)
    }
    pub async fn request(&self, method: &str, p: &Value) -> Result<Value> {
        let i = identity(p)?;
        match method {
            "agent_runtime_reconcile" => {
                let event = text(p, "eventID")?;
                let original = text(p, "originalHostSessionID")?;
                let call = text(p, "callID")?;
                let operation = text(p, "operationID")?;
                let outcome = text(p, "outcome")?;
                let verification = &p["verificationReceipt"];
                if !["applied", "not_applied"].contains(&outcome.as_str())
                    || verification["kind"] != "host_state_verification"
                    || verification["verifiedAtMillis"].as_u64().is_none()
                    || verification["observedState"]
                        .as_object()
                        .is_none_or(|v| v.is_empty())
                    || verification.to_string().len() > 16384
                    || [
                        "worldID",
                        "residentScope",
                        "hostSessionID",
                        "originalHostSessionID",
                        "runID",
                        "eventID",
                        "callID",
                        "operationID",
                        "outcome",
                    ]
                    .iter()
                    .any(|k| verification[*k] != p[*k])
                {
                    return Err("agent_runtime_invalid_verification".into());
                }
                let request = p.clone();
                let result=self.db.call(move|store|{
                    let state=agent_scheduler::request(&mut store.connection,"agent_loop_read",&request)?;
                    if state["config"]["hostSessionID"]!=request["hostSessionID"]{return Err("agent_runtime_stale_session");}
                    let event_record=state["events"].as_array().and_then(|events|events.iter().find(|e|e["eventID"]==event&&e["runID"]==request["runID"]&&e["hostSessionID"]==original)).ok_or("agent_runtime_reconciliation_mismatch")?;
                    let encoded=crate::canonical_json::to_string(&request["verificationReceipt"]).map_err(|_|"agent_runtime_invalid_verification")?;
                    let duplicate_run=event_record["state"]=="failed"
                        && event_record["receipt"]["source"]=="rutis-runtime-reconciliation"
                        && event_record["receipt"]["allToolsVerified"]==true
                        && crate::canonical_json::to_string(&event_record["receipt"]["lastVerification"]).map_err(|_|"agent_runtime_invalid_verification")?==encoded;
                    if event_record["state"]!="unknown"&&!duplicate_run{return Err("agent_runtime_reconciliation_mismatch");}
                    use rusqlite::OptionalExtension;
                    let row:Option<(String,String,Option<String>)>=store.connection.query_row(
                        "SELECT operation,state,receipt FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND call=?5",
                        rusqlite::params![request["worldID"].as_str(),request["residentScope"].as_str(),request["runID"].as_str(),original,call],
                        |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)),
                    ).optional().map_err(|_|"storage_unavailable")?;
                    let (stored_operation,tool_state,old_receipt)=row.ok_or("agent_runtime_reconciliation_mismatch")?;
                    if stored_operation!=operation{return Err("agent_runtime_reconciliation_mismatch");}
                    let mut tool_params=request.clone();tool_params["hostSessionID"]=json!(original);
                    if tool_state=="unknown" {
                        if duplicate_run{return Err("agent_runtime_reconciliation_mismatch");}
                        crate::agent_tools::reconcile(&mut store.connection,&tool_params)?;
                    } else {
                        let expected=if outcome=="applied"{"finished"}else{"not_applied"};
                        if tool_state!=expected||old_receipt.as_deref()!=Some(encoded.as_str()){return Err("agent_runtime_reconciliation_mismatch");}
                    }
                    let remaining:i64=store.connection.query_row("SELECT count(*) FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND state IN ('unknown','inflight')",rusqlite::params![request["worldID"].as_str(),request["residentScope"].as_str(),request["runID"].as_str()],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                    if remaining>0{return Ok(json!({"reconciled":true,"remainingUnknownTools":remaining,"runReleased":false}));}
                    if duplicate_run{return Ok(json!({"reconciled":true,"duplicate":true,"remainingUnknownTools":0,"runReleased":true,"state":"failed"}));}
                    let mut run_params=request.clone();run_params["outcome"]=json!("failed");run_params["receipt"]=json!({"source":"rutis-runtime-reconciliation","status":"failed","allToolsVerified":true,"lastVerification":request["verificationReceipt"]});
                    agent_scheduler::request(&mut store.connection,"agent_loop_reconcile",&run_params)?;
                    Ok(json!({"reconciled":true,"remainingUnknownTools":0,"runReleased":true,"state":"failed"}))
                }).await.map_err(str::to_owned)?;
                if result["runReleased"] == true {
                    if let Some(session) = self.sessions.lock().await.get(&key(&i)).cloned() {
                        if session.identity.run_id == i.run_id
                            && session.identity.session_id == text(p, "originalHostSessionID")?
                        {
                            session.cancellation.cancel();
                            session.runtime.cancel();
                            *session.state.lock().await = "failed".into();
                        }
                    }
                }
                Ok(result)
            }
            "agent_runtime_configure" => {
                if p.to_string().len() > 1024 * 1024 {
                    return Err("agent_runtime_input_limit".into());
                }
                let event = text(p, "eventID")?;
                self.claimed(&i, &event).await?;
                if p.get("images").is_some() || p.get("steering").is_some() {
                    return Err("agent_runtime_unsupported_input".into());
                }
                let tools = p["tools"]
                    .as_array()
                    .filter(|v| v.len() <= 64)
                    .ok_or("agent_runtime_invalid_tools")?;
                let operations = p["operations"]
                    .as_array()
                    .filter(|v| v.len() <= 128)
                    .ok_or("agent_runtime_invalid_operations")?;
                let mut grants = Vec::new();
                for op in operations {
                    if op["arguments"].to_string().len() > 16384 {
                        return Err("agent_runtime_invalid_operations".into());
                    }
                    grants.push(Grant {
                        operation: text(op, "operationID")?,
                        tool: text(op, "toolName")?,
                        args: op["arguments"].clone(),
                    });
                }
                let mut schemas = Vec::new();
                let mut allowed = std::collections::HashSet::new();
                for t in tools {
                    let name = text(t, "name")?;
                    if !allowed.insert(name.clone()) {
                        return Err("agent_runtime_duplicate_tool".into());
                    }
                    schemas.push(HostToolSchema {
                        name,
                        description: t["description"].as_str().unwrap_or("").to_owned(),
                        parameters: t["inputSchema"].clone(),
                    });
                }
                let provider = &p["provider"];
                let supports_images = match provider.get("imageInput") {
                    None => false,
                    Some(Value::Bool(v)) => *v,
                    _ => return Err("agent_runtime_invalid_provider".into()),
                };
                let mut provider_config = ProviderConfig::new(
                    text(provider, "backend")?,
                    provider["endpoint"]
                        .as_str()
                        .ok_or("agent_runtime_invalid_provider")?
                        .into(),
                    text(provider, "model")?,
                    provider["apiKey"]
                        .as_str()
                        .ok_or("agent_runtime_invalid_provider")?
                        .into(),
                );
                provider_config.image_input = supports_images;
                let model = build_provider(provider_config).map_err(|e| e.to_string())?;
                let prompt = p["systemPrompt"].as_str().unwrap_or("");
                if prompt.len() > 65536 {
                    return Err("agent_runtime_input_limit".into());
                }
                let queue = Arc::new(Queue::default());
                let dynamic = match p.get("dynamicAuthorization") {
                    None => false,
                    Some(Value::Bool(v)) => *v,
                    _ => return Err("agent_runtime_invalid_request".into()),
                };
                let grants = Arc::new(Grants {
                    identity: i.clone(),
                    items: std::sync::Mutex::new(grants),
                    dynamic: dynamic.then(|| queue.clone()),
                });
                let executor = Arc::new(LedgerHostTools::new(
                    self.db.clone(),
                    grants.clone(),
                    Arc::new(Transport(queue.clone())),
                ));
                let mut sessions = self.sessions.lock().await;
                if let Some(previous) = sessions.get(&key(&i)) {
                    let state = previous.state.lock().await.clone();
                    let externally_verified = if state == "unknown" {
                        let old = params(&previous.identity);
                        let event = previous.event.clone();
                        self.db.call(move|store| {
                            use rusqlite::OptionalExtension;
                            let terminal:Option<String>=store.connection.query_row("SELECT state FROM agent_loop_events WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND event=?5",rusqlite::params![old["worldID"].as_str(),old["residentScope"].as_str(),old["runID"].as_str(),old["hostSessionID"].as_str(),event],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
                            let unresolved:i64=store.connection.query_row("SELECT count(*) FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND state IN ('unknown','inflight')",rusqlite::params![old["worldID"].as_str(),old["residentScope"].as_str(),old["runID"].as_str()],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                            Ok(unresolved==0&&terminal.as_deref().is_some_and(|s|["completed","failed","cancelled"].contains(&s)))
                        }).await.map_err(str::to_owned)?
                    } else {
                        false
                    };
                    if !externally_verified
                        && !["completed", "failed", "cancelled"].contains(&state.as_str())
                    {
                        return Err("agent_runtime_session_exists".into());
                    }
                    previous.runtime.shutdown().await?;
                    sessions.remove(&key(&i));
                }
                if sessions.len() >= 16 {
                    return Err("agent_runtime_session_limit".into());
                }
                executor.register(&i, json!(tools)).await?;
                let runtime = Arc::new(
                    RutisRuntime::new_host(
                        model,
                        schemas,
                        executor,
                        RuntimeConfig {
                            system_prompt: prompt.into(),
                            allowed_tools: allowed,
                            supports_images,
                            ..Default::default()
                        },
                    )
                    .await?,
                );
                sessions.insert(
                    key(&i),
                    Arc::new(Session {
                        identity: i,
                        event,
                        runtime,
                        queue,
                        state: Mutex::new("configured".into()),
                        text: Mutex::new(String::new()),
                        cancellation: gmgn_agent_runtime::CancellationToken::new(),
                        grants,
                        steering_answers: Mutex::new(HashMap::new()),
                    }),
                );
                Ok(json!({"configured":true}))
            }
            "agent_runtime_start" => {
                if p.get("steering").is_some() || p.get("attachments").is_some() {
                    return Err("agent_runtime_unsupported_input".into());
                }
                let input = p["input"]
                    .as_str()
                    .filter(|v| v.len() <= 65536)
                    .ok_or("agent_runtime_invalid_input")?
                    .to_owned();
                let s = self.session(&i).await?;
                let input = UserInput {
                    text: input,
                    images: decode_images(p)?,
                };
                s.runtime.validate_user_input(&input)?;
                self.claimed(&i, &s.event).await?;
                {
                    let mut state = s.state.lock().await;
                    if *state != "configured" {
                        return Err("agent_runtime_already_started".into());
                    }
                    *state = "running".into();
                }
                let db = self.db.clone();
                tokio::spawn(async move {
                    let mut rx = s.runtime.subscribe_text();
                    let result = {
                        let turn = s
                            .runtime
                            .followup_input_with_identity(input, s.identity.clone());
                        tokio::pin!(turn);
                        loop {
                            tokio::select! {biased; _=s.cancellation.cancelled()=>break None,r=&mut turn=>break Some(r),delta=rx.recv()=>{match delta{Ok(delta)=>{let mut out=s.text.lock().await;if out.len()+delta.len()>1024*1024{s.runtime.cancel();*s.state.lock().await="output_limit".into();}else{out.push_str(&delta);}},Err(_)=>{s.runtime.cancel();}}}}
                        }
                    };
                    // The completion can win select before its final text delta.
                    // Preserve the complete bounded result, not a truncated UI transcript.
                    if let Some(Ok(final_text)) = &result {
                        if final_text.len() <= 1024 * 1024 {
                            *s.text.lock().await = final_text.clone();
                        } else {
                            *s.state.lock().await = "output_limit".into();
                        }
                    }
                    let mut p = params(&s.identity);
                    p["eventID"] = json!(s.event);
                    let unknown=db.call({let p=p.clone();move|store|{let count:i64=store.connection.query_row("SELECT count(*) FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND state IN ('inflight','unknown')",rusqlite::params![p["worldID"].as_str(),p["residentScope"].as_str(),p["runID"].as_str()],|r|r.get(0)).map_err(|_|"storage_unavailable")?;Ok(count>0)}}).await.unwrap_or(true);
                    if unknown {
                        let p = p.clone();
                        let _ = db.call(move |store| {
                            store.connection.execute(
                                "UPDATE agent_loop_events SET state='unknown' WHERE world=?1 AND scope=?2 AND event=?3 AND run=?4 AND session=?5 AND state IN ('claimed','cancel_requested')",
                                rusqlite::params![p["worldID"].as_str(),p["residentScope"].as_str(),p["eventID"].as_str(),p["runID"].as_str(),p["hostSessionID"].as_str()],
                            ).map_err(|_|"storage_unavailable")?;
                            Ok(())
                        }).await;
                        *s.state.lock().await = "unknown".into();
                        return;
                    }
                    let cancelled = *s.state.lock().await == "cancel_requested";
                    let status = if cancelled {
                        "cancelled"
                    } else if result.as_ref().is_some_and(|r| r.is_ok())
                        && *s.state.lock().await != "output_limit"
                    {
                        "completed"
                    } else {
                        "failed"
                    };
                    p["status"] = json!(status);
                    p["receipt"] = json!({"source":"rutis-runtime","status":status,"reply":s.text.lock().await.clone()});
                    let method = if cancelled {
                        "agent_loop_confirm_cancel"
                    } else {
                        "agent_loop_complete"
                    };
                    let settled = db
                        .call(move |store| {
                            agent_scheduler::request(&mut store.connection, method, &p)
                        })
                        .await;
                    *s.state.lock().await = if settled.is_ok() { status } else { "unknown" }.into();
                });
                Ok(json!({"started":true}))
            }
            "agent_runtime_read" => {
                let s = self.session(&i).await?;
                let mut pending = s
                    .queue
                    .pending
                    .lock()
                    .await
                    .values()
                    .map(|v| v.request.clone())
                    .collect::<Vec<_>>();
                pending.extend(
                    s.queue
                        .authorization
                        .lock()
                        .await
                        .values()
                        .map(|v| v.request.clone()),
                );
                let state = s.state.lock().await.clone();
                let output = s.text.lock().await.clone();
                Ok(json!({"state":state,"text":output,"pendingTools":pending}))
            }
            "agent_runtime_authorize" => {
                let s = self.session(&i).await?;
                let call = text(p, "callID")?;
                let decision = text(p, "decision")?;
                let operation = match decision.as_str() {
                    "approved" => Some(text(p, "operationID")?),
                    "rejected" => None,
                    _ => return Err("agent_runtime_invalid_authorization".into()),
                };
                let tool = text(p, "toolName")?;
                if !p["arguments"].is_object() || p["arguments"].to_string().len() > 16384 {
                    return Err("agent_runtime_invalid_authorization".into());
                }
                let answer = json!({"callID":call,"toolName":tool,"arguments":p["arguments"],"decision":decision,"operationID":operation});
                let mut proposals = s.queue.authorization.lock().await;
                let mut answers = s.queue.authorization_answers.lock().await;
                if let Some(previous) = answers.get(&call) {
                    if *previous != answer {
                        return Err("agent_runtime_authorization_conflict".into());
                    }
                    return Ok(json!({"accepted":true,"duplicate":true,"decision":decision}));
                }
                if *s.state.lock().await != "running" || s.cancellation.is_cancelled() {
                    return Err("agent_runtime_authorization_not_pending".into());
                }
                let proposal = proposals
                    .get(&call)
                    .ok_or("agent_runtime_authorization_not_pending")?;
                if proposal.request["toolName"] != tool
                    || proposal.request["arguments"] != p["arguments"]
                {
                    return Err("agent_runtime_authorization_conflict".into());
                }
                let proposal = proposals.remove(&call).unwrap();
                answers.insert(call, answer);
                proposal
                    .tx
                    .send(operation.ok_or_else(|| "agent_runtime_operation_rejected".to_owned()))
                    .map_err(|_| "agent_runtime_authorization_not_pending")?;
                Ok(json!({"accepted":true,"duplicate":false,"decision":decision}))
            }
            "agent_runtime_steer" => {
                if p.get("images").is_some() || p.get("attachments").is_some() {
                    return Err("agent_runtime_unsupported_input".into());
                }
                let s = self.session(&i).await?;
                let message = text(p, "messageID")?;
                let event = text(p, "eventID")?;
                let guidance = p["input"]
                    .as_str()
                    .filter(|v| !v.trim().is_empty() && v.len() <= 65536)
                    .ok_or("agent_runtime_invalid_steering")?
                    .to_owned();
                let reference = p["inputRef"].clone();
                if reference["submissionID"] != message
                    || reference["inputSHA256"]
                        != format!("{:x}", Sha256::digest(guidance.as_bytes()))
                    || reference["imageReferences"] != json!([])
                    || event != s.event
                {
                    return Err("agent_runtime_invalid_steering".into());
                }
                let operations = p.get("operations").cloned().unwrap_or(json!([]));
                let updates = operations
                    .as_array()
                    .filter(|v| v.len() <= 128)
                    .ok_or("agent_runtime_invalid_operations")?
                    .iter()
                    .map(|g| {
                        if !g["arguments"].is_object() || g["arguments"].to_string().len() > 16384 {
                            return Err("agent_runtime_invalid_operations".into());
                        }
                        Ok(Grant {
                            operation: text(g, "operationID")?,
                            tool: text(g, "toolName")?,
                            args: g["arguments"].clone(),
                        })
                    })
                    .collect::<Result<Vec<_>>>()?;
                let fingerprint = json!({"input":guidance,"inputRef":reference,"operations":operations,"eventID":event});
                let mut answers = s.steering_answers.lock().await;
                if let Some(old) = answers.get(&message) {
                    if old["request"] != fingerprint {
                        return Err("agent_runtime_steering_conflict".into());
                    }
                    return Ok(
                        json!({"delivery":old["delivery"],"duplicate":true,"grantsApplied":old["grantsApplied"]}),
                    );
                }
                if answers.len() >= 128 {
                    return Err("agent_runtime_queue_limit".into());
                }
                self.claimed(&i, &s.event).await?;
                let mut admission = params(&i);
                admission["eventID"] = json!(event);
                admission["messageID"] = json!(message);
                admission["inputRef"] = reference;
                self.db.call(move|store|{
                    use rusqlite::OptionalExtension;
                    let row:Option<(String,String,String,String,String,String)>=store.connection.query_row("SELECT state,input_ref,event,run,session,mode FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 AND message=?3",rusqlite::params![admission["worldID"].as_str(),admission["residentScope"].as_str(),admission["messageID"].as_str()],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional().map_err(|_|"storage_unavailable")?;
                    let (state,stored_ref,event,run,session,mode)=row.ok_or("agent_runtime_steering_not_admitted")?;
                    let stored_ref:Value=serde_json::from_str(&stored_ref).map_err(|_|"storage_unavailable")?;
                    if state!="steer_claimed"||mode!="steering"||stored_ref!=admission["inputRef"]||event!=admission["eventID"]||run!=admission["runID"]||session!=admission["hostSessionID"]{return Err("agent_runtime_steering_not_admitted");}
                    Ok(())
                }).await.map_err(str::to_owned)?;
                let active = *s.state.lock().await == "running" && !s.cancellation.is_cancelled();
                let (delivery, applied) = {
                    let mut grants = s.grants.items.lock().unwrap();
                    if grants.len() + updates.len() > 128 {
                        return Err("agent_runtime_invalid_operations".into());
                    }
                    for update in &updates {
                        if grants.iter().any(|g| {
                            g.tool == update.tool
                                && g.args == update.args
                                && g.operation != update.operation
                        }) {
                            return Err("agent_runtime_steering_conflict".into());
                        }
                    }
                    let delivery = if active {
                        s.runtime.steer(&i, guidance)
                    } else {
                        gmgn_agent_runtime::SteeringDelivery::NotDelivered
                    };
                    let delivered =
                        matches!(delivery, gmgn_agent_runtime::SteeringDelivery::Delivered);
                    if delivered {
                        for update in updates {
                            if !grants.iter().any(|g| {
                                g.operation == update.operation
                                    && g.tool == update.tool
                                    && g.args == update.args
                            }) {
                                grants.push(update);
                            }
                        }
                    }
                    let wire = match delivery {
                        gmgn_agent_runtime::SteeringDelivery::Delivered => "delivered",
                        gmgn_agent_runtime::SteeringDelivery::NotDelivered => "not_delivered",
                    };
                    (wire, delivered)
                };
                answers.insert(
                    message,
                    json!({"request":fingerprint,"delivery":delivery,"grantsApplied":applied}),
                );
                Ok(json!({"delivery":delivery,"duplicate":false,"grantsApplied":applied}))
            }
            "agent_runtime_cancel" => {
                let s = self.session(&i).await?;
                // Synchronize with start before changing the durable scheduler state.
                let mut state = s.state.lock().await;
                let never_started = *state == "configured";
                let mut p = params(&i);
                p["eventID"] = json!(s.event);
                let cancel_params = p.clone();
                let v = self
                    .db
                    .call(move |store| {
                        agent_scheduler::request(
                            &mut store.connection,
                            "agent_loop_cancel",
                            &cancel_params,
                        )
                    })
                    .await
                    .map_err(str::to_owned)?;
                if v["cancelRequested"] == true {
                    *state = "cancel_requested".into();
                    s.cancellation.cancel();
                    s.runtime.cancel();
                    if never_started {
                        p["receipt"] = json!({"source":"rutis-runtime","status":"cancelled","executionStarted":false});
                        let confirmed = self
                            .db
                            .call(move |store| {
                                agent_scheduler::request(
                                    &mut store.connection,
                                    "agent_loop_confirm_cancel",
                                    &p,
                                )
                            })
                            .await
                            .map_err(str::to_owned)?;
                        *state = "cancelled".into();
                        return Ok(
                            json!({"cancelled":true,"state":"cancelled","receiptAccepted":confirmed["accepted"]}),
                        );
                    }
                }
                Ok(v)
            }
            "agent_runtime_tool_receipt" => {
                let s = self.session(&i).await?;
                let id = text(p, "callID")?;
                let images = decode_images(p)?;
                if !images.is_empty() {
                    s.runtime.validate_user_input(&UserInput {
                        text: String::new(),
                        images: images.clone(),
                    })?;
                }
                if p["output"].to_string().len() > 16384 {
                    return Err("agent_runtime_receipt_limit".into());
                }
                let mut queue = s.queue.pending.lock().await;
                let mut answers = s.queue.execution_answers.lock().await;
                let fingerprint = json!({"operationID":p["operationID"],"status":p["status"],"output":p["output"],"images":images.iter().map(|im|json!({"mediaType":im.media_type,"length":im.bytes.len(),"sha256":format!("{:x}",Sha256::digest(&im.bytes))})).collect::<Vec<_>>()});
                if let Some(old) = answers.get(&id) {
                    if *old == fingerprint {
                        return Ok(json!({"accepted":true,"duplicate":true}));
                    }
                    return Err("agent_runtime_receipt_mismatch".into());
                }
                let pending = queue.get(&id).ok_or("agent_runtime_receipt_not_pending")?;
                if p["operationID"] != pending.request["operationID"] {
                    return Err("agent_runtime_receipt_mismatch".into());
                }
                let status = match p["status"].as_str() {
                    Some("completed") => HostToolStatus::Completed,
                    Some("unknown") => HostToolStatus::Unknown,
                    Some("rejected") => HostToolStatus::Rejected,
                    _ => return Err("agent_runtime_invalid_receipt".into()),
                };
                let pending = queue.remove(&id).unwrap();
                pending
                    .tx
                    .send(HostToolReceipt {
                        identity: i,
                        call_id: id.clone(),
                        status,
                        output: p["output"].clone(),
                        images,
                    })
                    .map_err(|_| "agent_runtime_receipt_expired")?;
                answers.insert(id, fingerprint);
                Ok(json!({"accepted":true,"duplicate":false}))
            }
            _ => Err("unknown_method".into()),
        }
    }
}
