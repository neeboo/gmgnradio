use gmgn_agent_runtime::{codex_session::*, ImageInput, TurnIdentity};
use serde_json::{json, Value};

fn identity() -> TurnIdentity {
    TurnIdentity {
        world_id: "w".into(),
        scope_id: "scope".into(),
        session_id: "host-session".into(),
        run_id: "run".into(),
    }
}
fn config() -> Value {
    json!({"config":{"features":{"plugins":false,"apps":false,"hooks":false,"multi_agent":false,"multi_agent_v2":false,"image_generation":false,"shell_tool":false},"agents":{"enabled":false},"notify":[],"web_search":"live","cli_auth_credentials_store":"file","mcp_oauth_credentials_store":"file","mcp_servers":{"fixture.server":{"enabled":false,"secret":"PRIVATE"}}}})
}
fn session(resume: Option<&str>, silent: bool) -> CodexSession {
    CodexSession::new(
        identity(),
        "/fixture".into(),
        json!([{"type":"text","text":"hello","text_elements":[]}]),
        json!([{"name":"inspect_world","description":"fixture","inputSchema":{"type":"object"}}]),
        resume.map(str::to_owned),
        silent,
    )
    .unwrap()
}
fn send(events: Vec<CodexEvent>) -> Value {
    events
        .into_iter()
        .find_map(|e| {
            if let CodexEvent::Send(v) = e {
                Some(v)
            } else {
                None
            }
        })
        .unwrap()
}
fn prepare(s: &mut CodexSession) {
    assert_eq!(s.initialize().unwrap()["method"], "initialize");
    let events = s.receive(json!({"id":1,"result":{}})).unwrap();
    assert_eq!(events.len(), 2);
    let thread = send(s.receive(json!({"id":2,"result":config()})).unwrap());
    assert_eq!(thread["params"]["sandbox"], "read-only");
    assert_eq!(thread["params"]["approvalPolicy"], "never");
    assert_eq!(thread["params"]["runtimeWorkspaceRoots"], json!([]));
    let turn = send(
        s.receive(json!({"id":3,"result":{"thread":{"id":"thread"}}}))
            .unwrap(),
    );
    assert_eq!(turn["params"]["environments"], json!([]));
}
fn active(s: &mut CodexSession) {
    prepare(s);
    s.receive(json!({"id":4,"result":{"turn":{"id":"turn"}}}))
        .unwrap();
}
fn notification(method: &str, extra: Value) -> Value {
    let mut p = json!({"threadId":"thread","turnId":"turn"});
    for (k, v) in extra.as_object().unwrap() {
        p[k] = v.clone();
    }
    json!({"method":method,"params":p})
}
fn final_message(s: &mut CodexSession) {
    s.receive(notification(
        "item/completed",
        json!({"item":{"id":"final","type":"agentMessage","phase":"final_answer","text":"done"}}),
    ))
    .unwrap();
}
fn finish() -> Value {
    notification(
        "turn/completed",
        json!({"turn":{"id":"turn","status":"completed"}}),
    )
}
fn call(id: &str) -> Value {
    json!({"id":"rpc-tool","method":"item/tool/call","params":{"threadId":"thread","turnId":"turn","callId":id,"tool":"inspect_world","namespace":null,"arguments":{}}})
}
fn receipt(id: &str) -> CodexReceipt {
    CodexReceipt {
        identity: identity(),
        thread_id: "thread".into(),
        turn_id: "turn".into(),
        call_id: id.into(),
        success: true,
        output: json!({"ok":true}),
        images: vec![],
    }
}

#[test]
fn typed_tool_images_use_native_content_items_and_validate_before_consuming_call() {
    use base64::Engine;
    let png = base64::engine::general_purpose::STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6WQAAAAASUVORK5CYII=").unwrap();
    let mut s = session(None, true);
    active(&mut s);
    s.receive(call("image")).unwrap();
    let mut r = receipt("image");
    r.images = vec![ImageInput {
        bytes: png.clone(),
        media_type: "image/jpeg".into(),
    }];
    assert_eq!(s.tool_receipt(r).unwrap_err(), ProtocolError::InvalidFrame);
    let mut r = receipt("image");
    r.images = (0..5)
        .map(|_| ImageInput {
            bytes: png.clone(),
            media_type: "image/png".into(),
        })
        .collect();
    assert_eq!(
        s.tool_receipt(r).unwrap_err(),
        ProtocolError::BudgetExceeded
    );
    let mut r = receipt("image");
    let mut large = png.clone();
    large.resize(4 * 1024 * 1024 + 1, 0);
    r.images = vec![ImageInput {
        bytes: large,
        media_type: "image/png".into(),
    }];
    assert_eq!(
        s.tool_receipt(r).unwrap_err(),
        ProtocolError::BudgetExceeded
    );
    let mut r = receipt("image");
    r.images = vec![ImageInput {
        bytes: png.clone(),
        media_type: "image/png".into(),
    }];
    let response = s.tool_receipt(r).unwrap();
    let items = response["result"]["contentItems"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["type"], "inputText");
    assert_eq!(items[1]["type"], "inputImage");
    assert_eq!(
        items[1]["imageUrl"],
        format!(
            "data:image/png;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(png)
        )
    );
    assert!(items[1].get("path").is_none());
    assert!(items[1].get("url").is_none());
    assert!(s.tool_receipt(receipt("image")).is_err());
    s.receive(finish()).unwrap();
    assert_eq!(s.state(), SessionState::Completed);
}

#[test]
fn real_protocol_sequence_text_tool_receipt_and_final() {
    let mut s = session(None, false);
    active(&mut s);
    let events = s
        .receive(notification(
            "item/agentMessage/delta",
            json!({"itemId":"final","delta":"do"}),
        ))
        .unwrap();
    assert!(matches!(&events[0],CodexEvent::TextDelta{text,..} if text=="do"));
    assert!(
        matches!(&s.receive(call("call" )).unwrap()[0],CodexEvent::ToolRequest{identity:i,call_id,..} if i==&identity() && call_id=="call")
    );
    let response = s.tool_receipt(receipt("call")).unwrap();
    assert_eq!(response["id"], "rpc-tool");
    assert_eq!(response["result"]["success"], true);
    final_message(&mut s);
    assert!(
        matches!(&s.receive(finish()).unwrap()[0],CodexEvent::Terminal{state:SessionState::Completed,reply} if reply=="done")
    );
    assert!(s.receive(call("new")).unwrap().is_empty());
}
#[test]
fn stale_unauthorized_duplicate_and_receipt_identity_are_isolated() {
    let mut s = session(None, false);
    active(&mut s);
    for field in ["threadId", "turnId", "tool", "namespace"] {
        let mut frame = call("x");
        frame["params"][field] = json!("other");
        assert_eq!(send(s.receive(frame).unwrap())["result"]["success"], false);
    }
    assert!(matches!(
        &s.receive(call("x")).unwrap()[0],
        CodexEvent::ToolRequest { .. }
    ));
    assert_eq!(
        send(s.receive(call("x")).unwrap())["result"]["success"],
        false
    );
    let mut r = receipt("x");
    r.identity.session_id = "old".into();
    assert_eq!(
        s.tool_receipt(r).unwrap_err(),
        ProtocolError::IdentityMismatch
    );
    s.tool_receipt(receipt("x")).unwrap();
    assert_eq!(
        s.tool_receipt(receipt("x")).unwrap_err(),
        ProtocolError::UnmatchedReceipt
    );
    let mut stale = finish();
    stale["params"]["threadId"] = json!("old");
    assert!(s.receive(stale).unwrap().is_empty());
    assert_eq!(s.state(), SessionState::Active);
}
#[test]
fn early_completion_waits_for_rpc_identity_and_mismatch_cannot_succeed() {
    for wrong in [false, true] {
        let mut s = session(None, false);
        prepare(&mut s);
        s.receive(notification("turn/started", json!({"turn":{"id":"turn"}})))
            .unwrap();
        final_message(&mut s);
        assert!(s.receive(finish()).unwrap().is_empty());
        assert_eq!(s.state(), SessionState::TurnStarting);
        let result =
            s.receive(json!({"id":4,"result":{"turn":{"id":if wrong {"wrong"} else {"turn"}}}}));
        if wrong {
            assert_eq!(result.err(), Some(ProtocolError::IdentityMismatch));
            assert_eq!(s.state(), SessionState::Failed);
        } else {
            assert!(matches!(
                &result.unwrap()[0],
                CodexEvent::Terminal {
                    state: SessionState::Completed,
                    ..
                }
            ));
        }
    }
}
#[test]
fn eof_interrupt_and_unresolved_tools_never_complete_or_replay() {
    let mut s = session(None, false);
    active(&mut s);
    s.receive(call("x")).unwrap();
    assert!(matches!(
        &s.disconnected()[0],
        CodexEvent::Terminal {
            state: SessionState::Unknown,
            ..
        }
    ));
    assert!(s.tool_receipt(receipt("x")).is_err());
    assert!(s.disconnected().is_empty());
    let mut s = session(None, false);
    active(&mut s);
    assert_eq!(send(s.interrupt())["method"], "turn/interrupt");
    assert!(s.interrupt().is_empty());
    assert_eq!(
        send(s.receive(call("x")).unwrap())["result"]["success"],
        false
    );
    final_message(&mut s);
    s.receive(finish()).unwrap();
    assert_eq!(s.state(), SessionState::Failed);
    let mut s = session(None, false);
    active(&mut s);
    s.receive(call("x")).unwrap();
    final_message(&mut s);
    s.receive(finish()).unwrap();
    assert_eq!(s.state(), SessionState::Failed);
}
#[test]
fn strict_terminal_retry_and_silent_completion() {
    for successful_tool in [false, true] {
        let mut s = session(None, true);
        active(&mut s);
        s.receive(notification(
            "error",
            json!({"willRetry":true,"error":{"message":"PRIVATE"}}),
        ))
        .unwrap();
        assert_eq!(s.state(), SessionState::Active);
        if successful_tool {
            s.receive(call("x")).unwrap();
            s.tool_receipt(receipt("x")).unwrap();
        }
        s.receive(finish()).unwrap();
        assert_eq!(
            s.state(),
            if successful_tool {
                SessionState::Completed
            } else {
                SessionState::Failed
            }
        );
    }
    let mut s = session(None, false);
    active(&mut s);
    s.receive(notification("item/completed",json!({"item":{"id":"comment","type":"agentMessage","phase":"commentary","text":"not final"}}))).unwrap();
    s.receive(finish()).unwrap();
    assert_eq!(s.state(), SessionState::Failed);
    let mut s = session(None, false);
    active(&mut s);
    final_message(&mut s);
    let mut failed = finish();
    failed["params"]["turn"]["status"] = json!("failed");
    s.receive(failed).unwrap();
    assert_eq!(s.state(), SessionState::Failed);
}
#[test]
fn effective_policy_tools_resume_and_frames_fail_closed() {
    for feature in [
        "plugins",
        "apps",
        "hooks",
        "multi_agent",
        "multi_agent_v2",
        "image_generation",
        "shell_tool",
    ] {
        let mut c = config();
        c["config"]["features"][feature] = json!(true);
        assert_eq!(
            verify_configuration(&c),
            Err(ProtocolError::UnsafeConfiguration)
        );
    }
    let mut c = config();
    c["config"]["mcp_servers"]["fixture.server"]["enabled"] = json!(true);
    assert!(verify_configuration(&c).is_err());
    let mut s = session(Some("old"), false);
    s.initialize().unwrap();
    s.receive(json!({"id":1,"result":{}})).unwrap();
    assert_eq!(
        send(s.receive(json!({"id":2,"result":config()})).unwrap())["method"],
        "thread/resume"
    );
    assert_eq!(
        s.receive(json!({"id":3,"result":{"thread":{"id":"different"}}}))
            .err(),
        Some(ProtocolError::IdentityMismatch)
    );
    assert_eq!(s.state(), SessionState::Failed);
    let mut s = session(None, false);
    active(&mut s);
    assert_eq!(
        send(
            s.receive(
                json!({"id":"approval","method":"item/permissions/requestApproval","params":{}})
            )
            .unwrap()
        )["error"]["code"],
        -32601
    );
    assert_eq!(
        s.receive(json!([])).err(),
        Some(ProtocolError::InvalidFrame)
    );
    assert_eq!(s.state(), SessionState::Failed);
}
