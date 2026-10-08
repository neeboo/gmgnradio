use gmgn_agent_runtime::chat_cli::{
    self, ChatBackend as B, ChatCliConfig, ChatCliError as E, ChatCliRequest, ChatMessage,
};
use std::{collections::BTreeMap, path::PathBuf, time::Duration};
fn config() -> ChatCliConfig {
    ChatCliConfig {
        executable: PathBuf::from("/private/mock"),
        environment: BTreeMap::new(),
        working_directory: PathBuf::from("/private"),
        private_root: PathBuf::from("/private"),
        lifetime: Duration::from_secs(5),
        claude_empty_mcp_config: None,
        claude_config_directory: None,
    }
}
fn request(backend: B) -> ChatCliRequest {
    ChatCliRequest {
        backend,
        input: "你好".into(),
        native_session_id: None,
        fresh_session_id: Some("host-uuid".into()),
        history: vec![],
        images: vec![],
    }
}
#[test]
fn exact_native_argv_and_stdin() {
    for (b, expected, stdin) in [
        (B::Codex, vec!["exec", "--json", "-"], "你好"),
        (
            B::Workbuddy,
            vec!["-p", "你好", "--output-format", "json"],
            "",
        ),
        (
            B::Qoder,
            vec![
                "-p",
                "你好",
                "--output-format",
                "json",
                "--session-id",
                "host-uuid",
            ],
            "",
        ),
        (B::Pi, vec!["--mode", "json", "-p", "你好"], ""),
        (B::Dsh, vec!["--profile", "headless", "用户：你好"], ""),
    ] {
        assert_eq!(
            chat_cli::arguments(&request(b), &config()).unwrap(),
            (
                expected.into_iter().map(str::to_owned).collect(),
                stdin.into()
            )
        );
    }
    let mut r = request(B::Workbuddy);
    r.native_session_id = Some("host-session".into());
    assert_eq!(
        chat_cli::arguments(&r, &config()).unwrap().0,
        vec![
            "-p",
            "--resume",
            "host-session",
            "你好",
            "--output-format",
            "json"
        ]
    );
    r.native_session_id = Some("--unsafe".into());
    assert_eq!(
        chat_cli::arguments(&r, &config()).unwrap_err(),
        E::InvalidSession
    );
}
#[test]
fn native_result_session_and_final_precedence() {
    for b in [B::Workbuddy, B::Qoder] {
        let result =
            chat_cli::parse_result(b, 0, r#"{"result":"答复","session_id":"session"}"#).unwrap();
        assert_eq!(result.reply, "答复");
        assert_eq!(result.native_session_id.as_deref(), Some("session"));
    }
    let codex="{\"type\":\"thread.started\",\"thread_id\":\"thread\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}";
    assert_eq!(
        chat_cli::parse_result(B::Codex, 0, codex).unwrap().reply,
        "done"
    );
    let pi="{\"type\":\"session\",\"id\":\"pi-session\"}\n{\"type\":\"message_update\",\"text_delta\":\"old\"}\n{\"type\":\"turn_end\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"final\"}]}}";
    assert_eq!(chat_cli::parse_result(B::Pi, 0, pi).unwrap().reply, "final");
    for b in [B::Codex, B::Workbuddy, B::Qoder, B::Pi, B::Dsh, B::Claude] {
        assert_eq!(
            chat_cli::parse_result(b, 7, "secret").unwrap_err(),
            E::ExecutionFailed
        );
        assert!(chat_cli::parse_result(b, 0, "").is_err());
    }
    assert_eq!(
        chat_cli::parse_result(B::Claude, 0, r#"{"is_error":1,"result":"bad"}"#).unwrap_err(),
        E::InvalidResult
    );
}
#[test]
fn unicode_history_is_bounded_without_partial_scalar() {
    let mut r = request(B::Dsh);
    r.history = (0..8)
        .map(|i| ChatMessage {
            user: i % 2 == 0,
            text: "界".repeat(9000),
        })
        .collect();
    let args = chat_cli::arguments(&r, &config()).unwrap().0;
    assert_eq!(args[2].matches('界').count(), 6 * 8000);
    r.images.push(PathBuf::from("/private/outside"));
    assert_eq!(
        chat_cli::arguments(&r, &config()).unwrap_err(),
        E::ImagesUnsupported
    );
}
#[cfg(unix)]
#[tokio::test]
async fn private_mock_full_output_fixed_environment_and_claude_policy() {
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        sync::atomic::{AtomicU64, Ordering},
    };
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let root = std::env::temp_dir().join(format!(
        "gmgn-chat-{}-{}",
        std::process::id(),
        SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let executable = root.join("mock");
    fs::write(&executable,"#!/bin/sh\n[ -z \"$NODE_OPTIONS\" ] || exit 8\nprintf 'private stderr' >&2\nprintf '{\"result\":\"mock reply\",\"session_id\":\"mock-session\"}'\n").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    let empty = root.join("mcp.json");
    fs::write(&empty, r#"{"mcpServers":{}}"#).unwrap();
    let mut c = config();
    c.executable = executable;
    c.working_directory = root.clone();
    c.private_root = root.clone();
    c.claude_empty_mcp_config = Some(empty.clone());
    c.claude_config_directory = Some(root.clone());
    c.environment
        .insert("NODE_OPTIONS".into(), "must-not-pass".into());
    c.environment
        .insert("ANTHROPIC_API_KEY".into(), "inert-test".into());
    let argv = chat_cli::arguments(&request(B::Claude), &c).unwrap().0;
    assert!(argv.contains(&"--no-session-persistence".into()));
    assert!(!argv.contains(&"--allowedTools".into()));
    assert!(!argv.contains(&"--resume".into()));
    fs::write(&empty, r#"{"mcpServers":{"unsafe":{}}}"#).unwrap();
    assert_eq!(
        chat_cli::arguments(&request(B::Claude), &c).unwrap_err(),
        E::InvalidConfiguration
    );
    fs::write(&empty, r#"{"mcpServers":{}}"#).unwrap();
    let out = chat_cli::run(
        c,
        request(B::Workbuddy),
        gmgn_agent_runtime::CancellationToken::new(),
    )
    .await
    .unwrap();
    assert_eq!(out.reply, "mock reply");
    assert_eq!(out.native_session_id.as_deref(), Some("mock-session"));
}
