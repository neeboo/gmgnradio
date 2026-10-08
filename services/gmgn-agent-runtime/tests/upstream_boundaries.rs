//! Regression tests for the two minimal audited upstream patches.
//! No network or platform tools are used.
use aimux_core::{
    options::CallOptions,
    result::{GenerateResult, StreamResult},
    AiMuxError, LanguageModel,
};
use async_trait::async_trait;
use futures::StreamExt;
use gmgn_agent_runtime::{LlmResponse, RuntimeConfig, RutisRuntime, ScriptedLlm};
use std::{sync::Arc, time::Duration};

struct NeverOpens(Arc<tokio::sync::Notify>);
#[async_trait]
impl LanguageModel for NeverOpens {
    fn provider(&self) -> &str {
        "test"
    }
    fn model_id(&self) -> &str {
        "never-opens"
    }
    async fn do_generate(&self, _: &CallOptions) -> Result<GenerateResult, AiMuxError> {
        std::future::pending().await
    }
    async fn do_stream(&self, _: &CallOptions) -> Result<StreamResult, AiMuxError> {
        self.0.notify_one();
        std::future::pending().await
    }
}
#[tokio::test]
async fn cancel_interrupts_stream_open() {
    let entered = Arc::new(tokio::sync::Notify::new());
    let runtime = Arc::new(
        RutisRuntime::new(
            Arc::new(NeverOpens(entered.clone())),
            vec![],
            RuntimeConfig::default(),
        )
        .await
        .unwrap(),
    );
    let r = runtime.clone();
    let mut turn = tokio::spawn(async move { r.followup("test").await });
    tokio::time::timeout(Duration::from_secs(1), entered.notified())
        .await
        .unwrap();
    runtime.cancel();
    assert!(matches!(
        tokio::time::timeout(Duration::from_secs(1), &mut turn)
            .await
            .unwrap()
            .unwrap(),
        Err(rutis_agent::AgentError::Stopped)
    ));
    runtime.shutdown().await.unwrap();
}
struct MissingFinish(ScriptedLlm);
#[async_trait]
impl LanguageModel for MissingFinish {
    fn provider(&self) -> &str {
        "test"
    }
    fn model_id(&self) -> &str {
        "missing-finish"
    }
    async fn do_generate(&self, o: &CallOptions) -> Result<GenerateResult, AiMuxError> {
        self.0.do_generate(o).await
    }
    async fn do_stream(&self, o: &CallOptions) -> Result<StreamResult, AiMuxError> {
        let mut result = self.0.do_stream(o).await?;
        result.stream = Box::pin(result.stream.filter(|part| {
            futures::future::ready(!matches!(
                part,
                Ok(aimux_core::stream_part::StreamPart::Finish { .. })
            ))
        }));
        Ok(result)
    }
}
#[tokio::test]
async fn eof_without_finish_is_not_success() {
    let model = MissingFinish(ScriptedLlm::new(vec![LlmResponse::content("partial")]));
    let runtime = RutisRuntime::new(Arc::new(model), vec![], RuntimeConfig::default())
        .await
        .unwrap();
    assert!(
        matches!(runtime.followup("test").await, Err(rutis_agent::AgentError::Llm(reason)) if reason == "stream_ended_without_finish")
    );
    runtime.shutdown().await.unwrap();
}

#[tokio::test]
async fn eof_without_finish_never_executes_collected_tools() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let count = Arc::new(AtomicUsize::new(0));
    let calls = count.clone();
    let tool = rutis_agent::ToolDef::new_contextual(
        "gmgn_move",
        "move",
        serde_json::json!({"type":"object"}),
        move |_| {
            let calls = calls.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(serde_json::json!({"ok":true}))
            }
        },
    );
    let model = MissingFinish(ScriptedLlm::new(vec![LlmResponse::tool_calls(vec![
        rutis_agent::tool_call("unsafe", "gmgn_move", serde_json::json!({})),
    ])]));
    let config = RuntimeConfig {
        allowed_tools: ["gmgn_move".to_owned()].into_iter().collect(),
        ..Default::default()
    };
    let runtime = RutisRuntime::new(Arc::new(model), vec![tool], config)
        .await
        .unwrap();
    assert!(
        matches!(runtime.followup("test").await, Err(rutis_agent::AgentError::Llm(reason)) if reason == "stream_ended_without_finish")
    );
    assert_eq!(count.load(Ordering::SeqCst), 0);
    runtime.shutdown().await.unwrap();
}
