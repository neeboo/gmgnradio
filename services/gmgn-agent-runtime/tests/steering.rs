use aimux_core::{
    options::CallOptions,
    result::{GenerateResult, StreamResult},
    AiMuxError, LanguageModel,
};
use async_trait::async_trait;
use futures::StreamExt;
use gmgn_agent_runtime::*;
use rutis::BoxFuture;
use serde_json::json;
use std::{
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};

fn identity() -> TurnIdentity {
    TurnIdentity {
        world_id: "world".into(),
        scope_id: "scope".into(),
        session_id: "session".into(),
        run_id: "original-run".into(),
    }
}
struct HoldModel {
    first: AtomicBool,
    entered: Arc<tokio::sync::Notify>,
    inner: ScriptedLlm,
    opening: bool,
}
#[async_trait]
impl LanguageModel for HoldModel {
    fn provider(&self) -> &str {
        "test"
    }
    fn model_id(&self) -> &str {
        "held"
    }
    async fn do_generate(&self, o: &CallOptions) -> Result<GenerateResult, AiMuxError> {
        self.inner.do_generate(o).await
    }
    async fn do_stream(&self, o: &CallOptions) -> Result<StreamResult, AiMuxError> {
        if self.first.swap(false, Ordering::SeqCst) {
            if self.opening {
                self.entered.notify_one();
                return std::future::pending().await;
            }
            let entered = self.entered.clone();
            let mut r = ScriptedLlm::new(vec![LlmResponse::content("stale partial")])
                .do_stream(o)
                .await?;
            r.stream = Box::pin(
                r.stream
                    .filter(|p| {
                        futures::future::ready(!matches!(
                            p,
                            Ok(aimux_core::stream_part::StreamPart::Finish { .. })
                        ))
                    })
                    .chain(futures::stream::once(async move {
                        entered.notify_one();
                        std::future::pending().await
                    })),
            );
            Ok(r)
        } else {
            self.inner.do_stream(o).await
        }
    }
}
struct Unused;
impl HostToolExecutor for Unused {
    fn execute(&self, _: HostToolContext) -> BoxFuture<'static, Result<HostToolReceipt, String>> {
        panic!("no tools should execute")
    }
}
#[tokio::test]
async fn steering_replans_pending_model_open_and_stream_in_original_turn() {
    for opening in [true, false] {
        let entered = Arc::new(tokio::sync::Notify::new());
        let model = Arc::new(HoldModel {
            first: AtomicBool::new(true),
            entered: entered.clone(),
            inner: ScriptedLlm::new(vec![LlmResponse::content("guided")]),
            opening,
        });
        let r = Arc::new(
            RutisRuntime::new_host(
                model.clone(),
                vec![],
                Arc::new(Unused),
                RuntimeConfig::default(),
            )
            .await
            .unwrap(),
        );
        assert_eq!(
            r.steer(&identity(), "idle".into()),
            SteeringDelivery::NotDelivered
        );
        let turn = r.clone();
        let j = tokio::spawn(async move { turn.followup_with_identity("begin", identity()).await });
        tokio::time::timeout(Duration::from_secs(1), entered.notified())
            .await
            .unwrap();
        let mut stale = identity();
        stale.run_id = "wrong-run".into();
        assert_eq!(
            r.steer(&stale, "wrong".into()),
            SteeringDelivery::NotDelivered
        );
        assert_eq!(
            r.steer(&identity(), "human guidance".into()),
            SteeringDelivery::Delivered
        );
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), j)
                .await
                .unwrap()
                .unwrap()
                .unwrap(),
            "guided"
        );
        assert!(model.inner.calls.lock().unwrap()[0]
            .message_texts()
            .iter()
            .any(|(_, text)| text == "human guidance"));
        assert_eq!(
            r.steer(&identity(), "after terminal".into()),
            SteeringDelivery::NotDelivered
        );
        r.shutdown().await.unwrap();
    }
}
struct HeldTool {
    entered: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Notify>,
    calls: Arc<AtomicUsize>,
}
impl HostToolExecutor for HeldTool {
    fn execute(&self, c: HostToolContext) -> BoxFuture<'static, Result<HostToolReceipt, String>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.entered.notify_one();
        let release = self.release.clone();
        Box::pin(async move {
            release.notified().await;
            assert_eq!(c.identity, identity());
            Ok(HostToolReceipt {
                identity: c.identity,
                call_id: c.execution.call.tool_call_id,
                status: HostToolStatus::Completed,
                output: json!({"done":true}),
                images: vec![],
            })
        })
    }
}
#[tokio::test]
async fn tool_inflight_steer_keeps_receipt_skips_rest_and_bounds_queue() {
    let entered = Arc::new(tokio::sync::Notify::new());
    let release = Arc::new(tokio::sync::Notify::new());
    let calls = Arc::new(AtomicUsize::new(0));
    let model = Arc::new(ScriptedLlm::new(vec![
        LlmResponse::tool_calls(vec![
            rutis_agent::tool_call("one", "gmgn_move", json!({})),
            rutis_agent::tool_call("two", "gmgn_move", json!({})),
        ]),
        LlmResponse::content("guided"),
    ]));
    let r = Arc::new(
        RutisRuntime::new_host(
            model.clone(),
            vec![HostToolSchema {
                name: "gmgn_move".into(),
                description: "move".into(),
                parameters: json!({"type":"object"}),
            }],
            Arc::new(HeldTool {
                entered: entered.clone(),
                release: release.clone(),
                calls: calls.clone(),
            }),
            RuntimeConfig {
                allowed_tools: ["gmgn_move".into()].into_iter().collect(),
                ..Default::default()
            },
        )
        .await
        .unwrap(),
    );
    let turn = r.clone();
    let j = tokio::spawn(async move { turn.followup_with_identity("go", identity()).await });
    tokio::time::timeout(Duration::from_secs(1), entered.notified())
        .await
        .unwrap();
    for n in 0..16 {
        assert_eq!(
            r.steer(&identity(), format!("guidance {n}")),
            SteeringDelivery::Delivered
        );
    }
    assert_eq!(
        r.steer(&identity(), "over capacity".into()),
        SteeringDelivery::NotDelivered
    );
    release.notify_one();
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(1), j)
            .await
            .unwrap()
            .unwrap()
            .unwrap(),
        "guided"
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let second = model.calls.lock().unwrap()[1].message_texts();
    assert!(second
        .iter()
        .any(|(role, text)| *role == aimux_core::message::Role::Tool && text.contains("skipped")));
    assert!(second.iter().any(|(_, text)| text == "guidance 15"));
    r.shutdown().await.unwrap();
}

struct TerminalRaceModel {
    first: AtomicBool,
    entered: Arc<tokio::sync::Notify>,
    release: Arc<tokio::sync::Barrier>,
    inner: ScriptedLlm,
}
#[async_trait]
impl LanguageModel for TerminalRaceModel {
    fn provider(&self) -> &str {
        "test"
    }
    fn model_id(&self) -> &str {
        "terminal-race"
    }
    async fn do_generate(&self, o: &CallOptions) -> Result<GenerateResult, AiMuxError> {
        self.inner.do_generate(o).await
    }
    async fn do_stream(&self, o: &CallOptions) -> Result<StreamResult, AiMuxError> {
        let result = self.inner.do_stream(o).await?;
        if self.first.swap(false, Ordering::SeqCst) {
            self.entered.notify_one();
            self.release.wait().await;
        }
        Ok(result)
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn terminal_race_never_acknowledges_and_drops_guidance() {
    for _ in 0..20 {
        let entered = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Barrier::new(2));
        let model = Arc::new(TerminalRaceModel {
            first: AtomicBool::new(true),
            entered: entered.clone(),
            release: release.clone(),
            inner: ScriptedLlm::new(vec![
                LlmResponse::content("initial"),
                LlmResponse::content("guided"),
            ]),
        });
        let r = Arc::new(
            RutisRuntime::new_host(
                model.clone(),
                vec![],
                Arc::new(Unused),
                RuntimeConfig::default(),
            )
            .await
            .unwrap(),
        );
        let turn = r.clone();
        let j = tokio::spawn(async move { turn.followup_with_identity("begin", identity()).await });
        tokio::time::timeout(Duration::from_secs(1), entered.notified())
            .await
            .unwrap();
        release.wait().await;
        let delivery = r.steer(&identity(), "race guidance".into());
        let answer = tokio::time::timeout(Duration::from_secs(1), j)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        match delivery {
            SteeringDelivery::Delivered => {
                assert_eq!(answer, "guided");
                assert!(model.inner.calls.lock().unwrap().iter().any(|call| call
                    .message_texts()
                    .iter()
                    .any(|(_, text)| text == "race guidance")));
            }
            SteeringDelivery::NotDelivered => assert_eq!(answer, "initial"),
        }
        assert_eq!(
            r.steer(&identity(), "too late".into()),
            SteeringDelivery::NotDelivered
        );
        r.shutdown().await.unwrap();
    }
}
