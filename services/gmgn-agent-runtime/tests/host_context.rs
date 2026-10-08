use gmgn_agent_runtime::*;
use rutis::BoxFuture;
use serde_json::json;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

fn identity() -> TurnIdentity {
    TurnIdentity {
        world_id: "world".into(),
        scope_id: "scope".into(),
        session_id: "session".into(),
        run_id: "run".into(),
    }
}
fn config() -> RuntimeConfig {
    RuntimeConfig {
        allowed_tools: ["gmgn_move".into()].into_iter().collect(),
        ..Default::default()
    }
}
fn schemas() -> Vec<HostToolSchema> {
    vec![HostToolSchema {
        name: "gmgn_move".into(),
        description: "move".into(),
        parameters: json!({"type":"object"}),
    }]
}
struct Executor {
    mode: &'static str,
    calls: Arc<AtomicUsize>,
}
impl HostToolExecutor for Executor {
    fn execute(
        &self,
        context: HostToolContext,
    ) -> BoxFuture<'static, Result<HostToolReceipt, String>> {
        let mode = self.mode;
        self.calls.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move {
            assert_eq!(context.identity, identity());
            assert_eq!(context.execution.call.tool_call_id, "call");
            assert_eq!(context.execution.call.input, json!({"x":1}));
            let mut receipt = HostToolReceipt {
                identity: context.identity,
                call_id: context.execution.call.tool_call_id,
                status: HostToolStatus::Completed,
                output: json!({"ok":true}),
                images: vec![],
            };
            match mode {
                "old_session" => receipt.identity.session_id = "old".into(),
                "wrong_call" => receipt.call_id = "other".into(),
                "unknown" => receipt.status = HostToolStatus::Unknown,
                "cancelled" => context.execution.cancellation.cancel(),
                "error" => return Err("do not expose secrets".into()),
                "panic" => panic!("executor interrupted"),
                _ => (),
            }
            Ok(receipt)
        })
    }
}
#[tokio::test]
async fn trusted_identity_and_matching_receipt_complete_real_rutis_turn() {
    let calls = Arc::new(AtomicUsize::new(0));
    let runtime = RutisRuntime::new_host(
        Arc::new(ScriptedLlm::new(vec![
            LlmResponse::tool_calls(vec![rutis_agent::tool_call(
                "call",
                "gmgn_move",
                json!({"x":1}),
            )]),
            LlmResponse::content("done"),
        ])),
        schemas(),
        Arc::new(Executor {
            mode: "ok",
            calls: calls.clone(),
        }),
        config(),
    )
    .await
    .unwrap();
    assert!(runtime.followup("go").await.is_err());
    assert_eq!(
        runtime
            .followup_with_identity("go", identity())
            .await
            .unwrap(),
        "done"
    );
    assert!(runtime
        .followup_with_identity("go", identity())
        .await
        .is_err());
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    runtime.shutdown().await.unwrap();
}
#[tokio::test]
async fn stale_unknown_mismatched_and_cancelled_results_never_succeed_or_retry() {
    for mode in [
        "old_session",
        "wrong_call",
        "unknown",
        "cancelled",
        "error",
        "panic",
    ] {
        let calls = Arc::new(AtomicUsize::new(0));
        let runtime = RutisRuntime::new_host(
            Arc::new(ScriptedLlm::new(vec![
                LlmResponse::tool_calls(vec![rutis_agent::tool_call(
                    "call",
                    "gmgn_move",
                    json!({"x":1}),
                )]),
                LlmResponse::content("pretend done"),
            ])),
            schemas(),
            Arc::new(Executor {
                mode,
                calls: calls.clone(),
            }),
            config(),
        )
        .await
        .unwrap();
        let result = runtime.followup_with_identity("go", identity()).await;
        assert!(result.is_err(), "{mode} must not become success");
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        if let Err(rutis_agent::AgentError::Pipeline(reason)) = result {
            assert!(!reason.contains("secrets"));
        }
        runtime.shutdown().await.unwrap();
    }
}
#[tokio::test]
async fn legacy_tools_are_not_accepted_by_gmgn_runtime() {
    let tool =
        rutis_agent::ToolDef::new("gmgn_move", "move", json!({"type":"object"}), |_| async {
            Ok(json!({}))
        });
    assert!(
        RutisRuntime::new(Arc::new(ScriptedLlm::new(vec![])), vec![tool], config())
            .await
            .is_err()
    );
}

struct PendingExecutor {
    entered: Arc<tokio::sync::Notify>,
    context: Arc<std::sync::Mutex<Option<rutis_agent::ToolExecutionContext>>>,
}
impl HostToolExecutor for PendingExecutor {
    fn execute(
        &self,
        context: HostToolContext,
    ) -> BoxFuture<'static, Result<HostToolReceipt, String>> {
        *self.context.lock().unwrap() = Some(context.execution);
        self.entered.notify_one();
        Box::pin(std::future::pending())
    }
}
#[tokio::test]
async fn host_cancel_propagates_to_executor_context() {
    let entered = Arc::new(tokio::sync::Notify::new());
    let context = Arc::new(std::sync::Mutex::new(None));
    let runtime = Arc::new(
        RutisRuntime::new_host(
            Arc::new(ScriptedLlm::new(vec![LlmResponse::tool_calls(vec![
                rutis_agent::tool_call("call", "gmgn_move", json!({"x":1})),
            ])])),
            schemas(),
            Arc::new(PendingExecutor {
                entered: entered.clone(),
                context: context.clone(),
            }),
            config(),
        )
        .await
        .unwrap(),
    );
    let r = runtime.clone();
    let turn = tokio::spawn(async move { r.followup_with_identity("go", identity()).await });
    tokio::time::timeout(std::time::Duration::from_secs(1), entered.notified())
        .await
        .unwrap();
    runtime.cancel();
    assert!(
        tokio::time::timeout(std::time::Duration::from_secs(3), turn)
            .await
            .unwrap()
            .unwrap()
            .is_err()
    );
    assert!(context
        .lock()
        .unwrap()
        .as_ref()
        .unwrap()
        .cancellation
        .is_cancelled());
    runtime.shutdown().await.unwrap();
}
