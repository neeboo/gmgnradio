use gmgn_agent_runtime::{claude_session::*, TurnIdentity};
use serde_json::json;
use std::collections::BTreeMap;
fn identity() -> TurnIdentity {
    TurnIdentity {
        world_id: "w".into(),
        scope_id: "s".into(),
        session_id: "h".into(),
        run_id: "r".into(),
    }
}
#[test]
fn strict_result_never_accepts_bad_types_or_nonterminal_output() {
    assert_eq!(parse_result(0, br#"{"result":"done"}"#).unwrap(), "done");
    assert_eq!(
        parse_result(
            0,
            br#"{"type":"result","subtype":"success","is_error":false,"result":""}"#
        )
        .unwrap(),
        ""
    );
    for value in [
        json!([]),
        json!({"result":null}),
        json!({"result":"x","type":null}),
        json!({"result":"x","subtype":"failed"}),
        json!({"result":"x","is_error":0}),
        json!({"result":"x","is_error":null}),
        json!({"result":"x","is_error":true}),
    ] {
        assert_eq!(
            parse_result(0, &serde_json::to_vec(&value).unwrap()),
            Err(ClaudeError::InvalidResult)
        );
    }
    assert!(parse_result(1, br#"{"result":"done"}"#).is_err());
    assert!(parse_result(0, b"PRIVATE-invalid").is_err());
}
#[test]
fn native_policy_only_registers_exact_mcp_tools_and_explicit_environment() {
    let p=ClaudePolicy::new(json!([{"name":"gmgn_inspect_world","description":"world","inputSchema":{"type":"object"}}])).unwrap();
    let args = p.arguments("/private/config.json").unwrap();
    assert!(args.contains(&"mcp__gmgn-resident-tools__gmgn_inspect_world".into()));
    assert!(args.contains(&"--bare".into()));
    assert!(args.windows(2).any(|v| v == ["--tools", ""]));
    assert!(!args
        .iter()
        .any(|s| s == "--resume" || s == "--dangerously-skip-permissions"));
    for name in [
        "bash",
        "gmgn_shell",
        "mcp__x__read_file",
        "web_search",
        "web_fetch",
    ] {
        assert!(ClaudePolicy::new(
            json!([{"name":name,"description":"bad","inputSchema":{"type":"object"}}])
        )
        .is_err());
    }
    assert!(p.validate_call("gmgn_inspect_world", &json!({})).is_ok());
    assert!(p.validate_call("gmgn_inspect_world", &json!(null)).is_err());
    let base = BTreeMap::from([
        ("HOME".into(), "/original".into()),
        ("ANTHROPIC_API_KEY".into(), " explicit-key ".into()),
        ("NODE_OPTIONS".into(), "PRIVATE".into()),
        ("CLAUDE_CODE_OTHER".into(), "PRIVATE".into()),
    ]);
    let env = environment(&base, "/private/config").unwrap();
    assert_eq!(env["HOME"], "/original");
    assert_eq!(env["ANTHROPIC_API_KEY"], "explicit-key");
    assert!(!env.contains_key("NODE_OPTIONS"));
    assert!(!env.contains_key("CLAUDE_CODE_OTHER"));
    assert_eq!(
        environment(&BTreeMap::new(), "/private/config"),
        Err(ClaudeError::MissingCredential)
    );
}
#[test]
fn pinned_grant_rechecks_expiry_identity_secret_round_before_and_after() {
    let mut g = ClaudeGrant {
        identity: GrantIdentity {
            world_id: "w".into(),
            scope_id: "s".into(),
            session_id: "h".into(),
            run_id: "r".into(),
            event_id: "e".into(),
        },
        secret: "12345678-1234-4234-8234-123456789abc".into(),
        round: "round1".into(),
        expires_at_ms: 100,
        armed: true,
    };
    let pinned = PinnedGrant::pin(&g, 1).unwrap();
    assert!(pinned.verify(&g, 2).is_ok());
    assert_eq!(pinned.verify(&g, 100), Err(ClaudeError::GrantExpired));
    g.round = "round2".into();
    assert_eq!(pinned.verify(&g, 2), Err(ClaudeError::GrantRevoked));
    g.round = "round1".into();
    g.identity.run_id = "new".into();
    assert!(pinned.verify(&g, 2).is_err());
    g.identity = GrantIdentity {
        world_id: "w".into(),
        scope_id: "s".into(),
        session_id: "h".into(),
        run_id: "r".into(),
        event_id: "e".into(),
    };
    g.armed = false;
    assert!(pinned.verify(&g, 2).is_err());
}
#[test]
fn history_only_records_real_messages_and_isolates_world_scope_and_session() {
    let i = identity();
    let mut history = ClaudeHistory::default();
    history.record(&i, None, "background reply");
    assert_eq!(history.prompt(&i, "now", None).unwrap(), "now");
    for n in 0..5 {
        history.record(&i, Some(&format!("user{n}")), &format!("reply{n}"));
    }
    let prompt = history.prompt(&i, "now", Some("memory-only")).unwrap();
    assert!(!prompt.contains("user0"));
    assert!(prompt.contains("user4"));
    assert!(prompt.contains("memory-only"));
    let mut other = i.clone();
    other.session_id = "other".into();
    assert_eq!(
        history.prompt(&other, "isolated", None).unwrap(),
        "isolated"
    );
    assert!(mcp_tool_result(&json!({"ok":true}), &[], true).unwrap()["isError"] == false);
}
