#![cfg(unix)]
use gmgn_agent_runtime::{
    chat_dsh::{composition, environment, ChatDshConfig, ChatDshIdentity, ChatDshSession},
    dsh_session::{DshEvent, DshSession},
    CancellationToken, ImageInput, UserInput,
};
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
fn identity(request: &str) -> ChatDshIdentity {
    ChatDshIdentity {
        scope_id: "actual-chat-scope".into(),
        host_session_id: "host".into(),
        request_id: request.into(),
    }
}
fn input() -> UserInput {
    UserInput {
        text: "看图".into(),
        images: vec![ImageInput {
            bytes: b"\x89PNG\r\n\x1a\nfixture".to_vec(),
            media_type: "image/png".into(),
        }],
    }
}
#[test]
fn ordinary_identity_image_and_permission_contract() {
    let mut session = DshSession::new_chat(identity("one"), "/private".into(), input()).unwrap();
    session.initialize().unwrap();
    session.receive(serde_json::json!({"id":1,"result":{"agentCapabilities":{"promptCapabilities":{"image":true}}}})).unwrap();
    let events = session
        .receive(serde_json::json!({"id":2,"result":{"sessionId":"native"}}))
        .unwrap();
    let prompt = events
        .into_iter()
        .find_map(|e| {
            if let DshEvent::Send(v) = e {
                Some(v)
            } else {
                None
            }
        })
        .unwrap();
    assert_eq!(prompt["params"]["prompt"][0]["mimeType"], "image/png");
    assert!(prompt["params"]["prompt"][0]["data"]
        .as_str()
        .unwrap()
        .starts_with("iVBOR"));
    let denied=session.receive(serde_json::json!({"id":88,"method":"session/request_permission","params":{"options":[{"kind":"reject_once","optionId":"deny"}]}})).unwrap();
    assert!(matches!(&denied[0],DshEvent::Send(v) if v["result"]["outcome"]["optionId"]=="deny"));
    session.receive(serde_json::json!({"method":"session/update","params":{"sessionId":"native","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}})).unwrap();
    session
        .receive(serde_json::json!({"id":3,"result":{"stopReason":"end_turn"}}))
        .unwrap();
    let mut foreign = identity("two");
    foreign.scope_id = "other".into();
    assert!(session.next_chat_turn(foreign, input()).is_err());
    assert_eq!(
        session.next_chat_turn(identity("two"), input()).unwrap()["params"]["sessionId"],
        "native"
    );
    let env = environment(&BTreeMap::from([
        ("DSH_SNAPSHOT".into(), "bad".into()),
        ("NODE_OPTIONS".into(), "bad".into()),
        ("USER".into(), "test".into()),
    ]));
    assert!(!env.contains_key("DSH_SNAPSHOT") && !env.contains_key("NODE_OPTIONS"));
    let yaml = composition("/private/attachments", "/private/history", "plain").unwrap();
    assert!(!yaml.contains("gmgn-host-tools"));
    assert!(yaml.contains("toolBash: false") && yaml.contains("inputModalities: [text, image]"));
}
#[tokio::test]
async fn private_acp_mock_reuses_native_session_and_cancel_reaps() {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let root = std::env::temp_dir().join(format!(
        "gmgn-chat-acp-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let executable = root.join("mock");
    fs::write(&executable,"#!/bin/sh\nIFS= read -r frame\nprintf '%s\\n' '{\"id\":1,\"result\":{\"agentCapabilities\":{\"promptCapabilities\":{\"image\":true}}}}'\nIFS= read -r frame\nprintf '%s\\n' '{\"id\":2,\"result\":{\"sessionId\":\"private-native\"}}'\ni=3\nwhile IFS= read -r frame; do\ncase \"$frame\" in *session/cancel*) echo cancelled > cancelled; continue;; esac\nprintf '%s\\n' '{\"method\":\"session/update\",\"params\":{\"sessionId\":\"private-native\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"reply\"}}}}'\nprintf '{\"id\":%s,\"result\":{\"stopReason\":\"end_turn\"}}\\n' \"$i\"\ni=$((i+1))\ndone\n").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let file = root.join("composition");
    fs::write(
        &file,
        composition(root.to_str().unwrap(), root.to_str().unwrap(), "plain").unwrap(),
    )
    .unwrap();
    let entry = root.join("entry");
    fs::write(&entry, "").unwrap();
    let cfg = ChatDshConfig {
        node_executable: executable,
        entry_point: entry,
        composition_file: file,
        cwd: root.clone(),
        environment: BTreeMap::new(),
        lifetime: Duration::from_secs(10),
        attachment_home: root.clone(),
        persistence_root: root,
        persona: "plain".into(),
    };
    let (mut actor, reply) =
        ChatDshSession::open(cfg, identity("one"), input(), CancellationToken::new())
            .await
            .unwrap();
    assert_eq!(reply, "reply");
    assert_eq!(actor.session_id(), Some("private-native"));
    assert_eq!(
        actor
            .turn(identity("two"), input(), CancellationToken::new())
            .await
            .unwrap(),
        "reply"
    );
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(actor
        .turn(identity("three"), input(), cancel)
        .await
        .is_err());
    assert!(!actor.is_usable());
    assert!(actor
        .turn(identity("four"), input(), CancellationToken::new())
        .await
        .is_err());
}
