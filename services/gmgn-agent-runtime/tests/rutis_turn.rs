use gmgn_agent_runtime::{LlmResponse, RuntimeConfig, RutisRuntime, ScriptedLlm};
use rutis_agent::{tool_call, AgentError, ToolDef};
use serde_json::json;
use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};

fn config() -> RuntimeConfig {
    RuntimeConfig {
        allowed_tools: ["gmgn_move".to_string()].into_iter().collect(),
        ..Default::default()
    }
}
fn tool(count: Arc<AtomicUsize>) -> ToolDef {
    ToolDef::new_contextual(
        "gmgn_move",
        "move in resident space",
        json!({"type":"object"}),
        move |context| {
            let count = count.clone();
            async move {
                count.fetch_add(1, Ordering::SeqCst);
                Ok(context.call.input)
            }
        },
    )
}
#[tokio::test]
async fn real_rutis_loop_calls_tool_returns_result_and_final_answer() {
    let model = Arc::new(ScriptedLlm::new(vec![
        LlmResponse::tool_calls(vec![tool_call("call-1", "gmgn_move", json!({"x":1}))]),
        LlmResponse::content("done"),
    ]));
    let count = Arc::new(AtomicUsize::new(0));
    let runtime = RutisRuntime::new(model.clone(), vec![tool(count.clone())], config())
        .await
        .unwrap();
    let mut events = runtime.subscribe_text();
    assert_eq!(runtime.followup("move").await.unwrap(), "done");
    assert_eq!(count.load(Ordering::SeqCst), 1);
    assert_eq!(model.calls.lock().unwrap().len(), 2);
    let second = model.calls.lock().unwrap()[1].message_texts();
    assert!(second
        .iter()
        .any(|(role, text)| *role == aimux_core::message::Role::Tool && text.contains("x")));
    assert!(tokio::time::timeout(Duration::from_secs(1), events.recv())
        .await
        .unwrap()
        .unwrap()
        .contains("done"));
    runtime.shutdown().await.unwrap();
}
#[tokio::test]
async fn unauthorized_calls_do_not_execute() {
    let model = Arc::new(ScriptedLlm::new(vec![
        LlmResponse::tool_calls(vec![
            tool_call("bad", "bash", json!({})),
            tool_call("one", "gmgn_move", json!({})),
        ]),
        LlmResponse::content("done"),
    ]));
    let count = Arc::new(AtomicUsize::new(0));
    let runtime = RutisRuntime::new(model, vec![tool(count.clone())], config())
        .await
        .unwrap();
    runtime.followup("test").await.unwrap();
    assert_eq!(count.load(Ordering::SeqCst), 1);
    runtime.shutdown().await.unwrap();
}

#[tokio::test]
async fn duplicated_model_batch_is_rejected_before_any_execution() {
    let model = Arc::new(ScriptedLlm::new(vec![LlmResponse::tool_calls(vec![
        tool_call("one", "gmgn_move", json!({})),
        tool_call("one", "gmgn_move", json!({})),
    ])]));
    let count = Arc::new(AtomicUsize::new(0));
    let runtime = RutisRuntime::new(model, vec![tool(count.clone())], config())
        .await
        .unwrap();
    assert!(runtime.followup("test").await.is_err());
    assert_eq!(count.load(Ordering::SeqCst), 0);
    runtime.shutdown().await.unwrap();
}
#[tokio::test]
async fn cancel_inflight_gmgn_tool() {
    let entered = Arc::new(tokio::sync::Notify::new());
    let notify = entered.clone();
    let tool = ToolDef::new_contextual("gmgn_move", "move", json!({"type":"object"}), move |_| {
        let notify = notify.clone();
        async move {
            notify.notify_one();
            std::future::pending::<Result<serde_json::Value, String>>().await
        }
    });
    let runtime = Arc::new(
        RutisRuntime::new(
            Arc::new(ScriptedLlm::new(vec![LlmResponse::tool_calls(vec![
                tool_call("one", "gmgn_move", json!({})),
            ])])),
            vec![tool],
            config(),
        )
        .await
        .unwrap(),
    );
    let turn = runtime.clone();
    let join = tokio::spawn(async move { turn.followup("go").await });
    tokio::time::timeout(Duration::from_secs(1), entered.notified())
        .await
        .unwrap();
    runtime.cancel();
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(3), join)
            .await
            .unwrap()
            .unwrap(),
        Err(AgentError::Stopped)
    ));
    runtime.shutdown().await.unwrap();
}
