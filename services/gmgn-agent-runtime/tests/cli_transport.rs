#![cfg(unix)]
use gmgn_agent_runtime::cli_transport::{
    CliConfig, CliError, OwnedCliTransport, MAX_FRAME_BYTES, MAX_WRITE_BYTES,
};
use serde_json::json;
use std::{
    collections::BTreeMap,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

struct Mock {
    root: PathBuf,
    executable: PathBuf,
}
static NEXT_MOCK: AtomicU64 = AtomicU64::new(0);
impl Mock {
    fn new() -> Self {
        let id = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        Self::with_stamp(id)
    }
    fn with_stamp(id: u128) -> Self {
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let root = loop {
            let sequence = NEXT_MOCK.fetch_add(1, Ordering::Relaxed);
            let candidate = temporary.join(format!(
                "gmgn-cli-mock-{}-{id}-{sequence}",
                std::process::id()
            ));
            match std::fs::create_dir(&candidate) {
                Ok(()) => break candidate,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("private mock directory creation failed: {:?}", error.kind()),
            }
        };
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let executable = root.join("owned-mock");
        let mut script=String::from("#!/bin/sh\ncase \"$1\" in\necho) while IFS= read -r line; do printf '%s\\n' \"$line\"; done ;;\nwait) while IFS= read -r line; do :; done ;;\nmalformed) printf '%s\\n' 'private-secret-unparseable' ;;\npartial) printf '%s' '{\"partial\":true}' ;;\nstderr) printf '%s\\n' 'private-secret-stderr-do-not-return' >&2; while IFS= read -r line; do printf '%s\\n' \"$line\"; done ;;\nenv) printf '{\"home\":\"%s\",\"explicit\":\"%s\"}\\n' \"${HOME-absent}\" \"${GMGN_MOCK_ONLY-absent}\"; while IFS= read -r line; do :; done ;;\nflood) while :; do printf '%s\\n' '{\"notification\":1}'; done ;;\nlarge) i=0; while [ \"$i\" -lt 1026 ]; do printf '%s' '");
        script = script.replacen(
            "wait) while",
            r#"count) while IFS= read -r line; do printf '{"received":%s}\n' "${#line}"; done ;;
wait) while"#,
            1,
        );
        script=script.replacen("wait) while",r#"launcher) "$0" descendant "$2" "$3" & child=$!; trap 'wait "$child"; exit 0' TERM; wait "$child" ;;
launcher_eof) "$0" descendant "$2" "$3" >/dev/null 2>&1 & child=$!; while [ ! -f "$3.ready" ]; do :; done; printf '{"child":%s}\n' "$child"; exit 0 ;;
descendant) exec 3<> "$2"; trap 'printf terminated > "$3"; exit 0' TERM; printf ready > "$3.ready"; printf '{"child":%s}\n' "$$"; while IFS= read -r line <&3; do :; done ;;
wait) while"#,1);
        script.push_str(&"x".repeat(1024));
        script.push_str("'; i=$((i+1)); done ;;\nesac\n");
        std::fs::write(&executable, script).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        Self { root, executable }
    }
    fn config(&self, mode: &str) -> CliConfig {
        CliConfig {
            executable: self.executable.clone(),
            arguments: vec![mode.into()],
            environment: BTreeMap::new(),
            working_directory: Some(self.root.clone()),
            lifetime: Duration::from_secs(3),
        }
    }
}
impl Drop for Mock {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn process_exists(pid: u32) -> bool {
    // Only PIDs returned by this fixture/owned spawn; no global process search.
    unsafe { libc::kill(i32::try_from(pid).unwrap(), 0) == 0 }
}
fn descendant_config(mock: &Mock, mode: &str) -> (CliConfig, PathBuf) {
    let fifo = mock.root.join("child-input");
    let report = mock.root.join("child-terminated");
    let path = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let mut config = mock.config(mode);
    config.arguments.extend([
        fifo.to_string_lossy().into_owned(),
        report.to_string_lossy().into_owned(),
    ]);
    (config, report)
}
async fn await_absent(pid: u32) {
    tokio::time::timeout(Duration::from_secs(2), async {
        while process_exists(pid) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn cancellation_reclaims_owned_launcher_group_without_reaping_leader_early() {
    let mock = Mock::new();
    let (config, report) = descendant_config(&mock, "launcher");
    let mut t = OwnedCliTransport::spawn(config).await.unwrap();
    let leader = t.process_id();
    let child = t.receive().await.unwrap()["child"].as_u64().unwrap() as u32;
    assert_ne!(leader, child);
    assert!(process_exists(child));
    let other = Mock::new();
    let mut survivor = OwnedCliTransport::spawn(other.config("echo"))
        .await
        .unwrap();
    t.cancel();
    tokio::time::timeout(Duration::from_secs(1), async {
        while !report.exists() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
    assert!(
        process_exists(leader),
        "leader PID remains reserved during TERM grace before group KILL/wait"
    );
    assert_eq!(t.wait_closed().await, CliError::Cancelled);
    // Check isolation immediately after the owned group cleanup, before the
    // separately bounded descendant-absence polls. Those polls can consume up
    // to four seconds under load, longer than the independent echo's unchanged
    // three-second lifetime; its own valid timeout is not a group-kill failure.
    survivor
        .send(&json!({"independent":"alive"}))
        .await
        .unwrap();
    assert_eq!(
        survivor.receive().await.unwrap(),
        json!({"independent":"alive"})
    );
    survivor.cancel();
    assert_eq!(survivor.wait_closed().await, CliError::Cancelled);
    await_absent(leader).await;
    await_absent(child).await;
}
#[tokio::test]
async fn deadline_and_eof_reclaim_private_descendants() {
    for mode in ["launcher", "launcher_eof"] {
        let mock = Mock::new();
        let (mut config, report) = descendant_config(&mock, mode);
        if mode == "launcher" {
            config.lifetime = Duration::from_secs(1);
        }
        // This regression checks cleanup after a known-live descendant. Keep
        // production's deadline unchanged, but freeze the fixture's clock until
        // the real subprocess handshake arrives. An inline yielding branch
        // prevents Tokio's paused clock from auto-advancing while external I/O
        // starts; a separate real-wall bound still rejects a stuck launcher.
        tokio::time::pause();
        let mut t = OwnedCliTransport::spawn(config).await.unwrap();
        let leader = t.process_id();
        let startup_bound = async {
            let deadline = std::time::Instant::now() + Duration::from_secs(10);
            while std::time::Instant::now() < deadline {
                tokio::task::yield_now().await;
            }
        };
        let ready = tokio::select! {
            frame = t.receive() => Some(frame),
            _ = startup_bound => None,
        };
        // Both inline branches have been dropped: there is no detached
        // heartbeat to leak. Restore time before every cleanup/error path.
        tokio::time::resume();
        let frame = match ready {
            Some(Ok(frame)) => frame,
            failed => {
                t.cancel();
                let terminal = t.wait_closed().await;
                await_absent(leader).await;
                panic!(
                    "{mode} child-ready handshake failed: {failed:?}; owned cleanup: {terminal}"
                );
            }
        };
        let child = frame["child"].as_u64().unwrap() as u32;
        assert!(
            process_exists(child),
            "handshake identifies a real live descendant"
        );
        let resumed = std::time::Instant::now();
        assert_eq!(
            t.wait_closed().await,
            if mode == "launcher" {
                CliError::TimedOut
            } else {
                CliError::ConnectionClosed
            }
        );
        if mode == "launcher" {
            assert!(
                resumed.elapsed() >= Duration::from_secs(1),
                "the unchanged one-second deadline actually elapsed after readiness"
            );
        }
        assert!(report.exists());
        await_absent(leader).await;
        await_absent(child).await;
    }
}

#[test]
fn fixture_creation_is_unique_with_identical_parallel_timestamps() {
    let workers: Vec<_> = (0..16)
        .map(|_| std::thread::spawn(|| Mock::with_stamp(0)))
        .collect();
    let mocks: Vec<_> = workers
        .into_iter()
        .map(|worker| worker.join().unwrap())
        .collect();
    let roots: std::collections::HashSet<_> = mocks.iter().map(|mock| mock.root.clone()).collect();
    assert_eq!(roots.len(), mocks.len());
}

#[tokio::test]
async fn exact_owned_echo_and_explicit_environment() {
    let mock = Mock::new();
    let mut t = OwnedCliTransport::spawn(mock.config("echo")).await.unwrap();
    t.send(&json!({"id":1,"params":{"text":"hello"}}))
        .await
        .unwrap();
    assert_eq!(
        t.receive().await.unwrap(),
        json!({"id":1,"params":{"text":"hello"}})
    );
    t.cancel();
    assert_eq!(t.wait_closed().await, CliError::Cancelled);
    let mut config = mock.config("env");
    config
        .environment
        .insert("GMGN_MOCK_ONLY".into(), "trusted".into());
    let mut t = OwnedCliTransport::spawn(config).await.unwrap();
    assert_eq!(
        t.receive().await.unwrap(),
        json!({"home":"absent","explicit":"trusted"})
    );
    t.cancel();
    t.wait_closed().await;
}
#[tokio::test]
async fn malformed_partial_and_oversize_have_only_fixed_errors() {
    let mock = Mock::new();
    for (mode, error) in [
        ("malformed", CliError::InvalidFrame),
        ("partial", CliError::InvalidFrame),
        ("large", CliError::FrameTooLarge),
    ] {
        let mut t = OwnedCliTransport::spawn(mock.config(mode)).await.unwrap();
        assert_eq!(t.receive().await.unwrap_err(), error);
        assert!(!format!("{error:?} {error}").contains("private-secret"));
        t.wait_closed().await;
    }
    let mut t = OwnedCliTransport::spawn(mock.config("echo")).await.unwrap();
    assert_eq!(
        t.send(&json!({"text":"x".repeat(MAX_WRITE_BYTES)}))
            .await
            .unwrap_err(),
        CliError::FrameTooLarge
    );
    t.cancel();
    t.wait_closed().await;
}

#[tokio::test]
async fn outbound_image_frame_can_exceed_read_limit_without_expanding_stdout_budget() {
    let mock = Mock::new();
    let mut config = mock.config("count");
    config.lifetime = Duration::from_secs(10);
    let mut t = OwnedCliTransport::spawn(config).await.unwrap();
    // Base64 of a 4MiB buffer beginning with the PNG header and otherwise zero.
    let encoded_len = ((4 * 1024 * 1024usize + 2) / 3) * 4;
    let image = format!(
        "data:image/png;base64,iVBORw0KGgoA{}==",
        "A".repeat(encoded_len - 14)
    );
    let frame = json!({"image":image,"text":"x".repeat(512*1024)});
    let encoded = serde_json::to_vec(&frame).unwrap();
    assert!(encoded.len() > MAX_FRAME_BYTES);
    assert!(encoded.len() < MAX_WRITE_BYTES);
    t.send(&frame).await.unwrap();
    assert_eq!(
        t.receive().await.unwrap(),
        json!({"received":encoded.len()})
    );
    assert_eq!(
        t.send(&json!({"tooLarge":"x".repeat(MAX_WRITE_BYTES)}))
            .await
            .unwrap_err(),
        CliError::FrameTooLarge
    );
    t.cancel();
    t.wait_closed().await;
    let mut t = OwnedCliTransport::spawn(mock.config("large"))
        .await
        .unwrap();
    assert_eq!(t.receive().await.unwrap_err(), CliError::FrameTooLarge);
    t.wait_closed().await;
}
#[tokio::test]
async fn stderr_is_not_a_model_frame_and_eof_is_detected() {
    let mock = Mock::new();
    let mut t = OwnedCliTransport::spawn(mock.config("stderr"))
        .await
        .unwrap();
    t.send(&json!({"id":2})).await.unwrap();
    assert_eq!(t.receive().await.unwrap(), json!({"id":2}));
    t.cancel();
    t.wait_closed().await;
    let mut t = OwnedCliTransport::spawn(mock.config("exit-immediately"))
        .await
        .unwrap();
    assert_eq!(t.receive().await.unwrap_err(), CliError::ConnectionClosed);
    assert_eq!(t.wait_closed().await, CliError::ConnectionClosed);
}
#[tokio::test]
async fn deadline_cancellation_and_backpressure_reap_only_owned_child() {
    let mock = Mock::new();
    let mut config = mock.config("wait");
    config.lifetime = Duration::from_millis(100);
    let mut timed = OwnedCliTransport::spawn(config).await.unwrap();
    assert_eq!(timed.receive().await.unwrap_err(), CliError::TimedOut);
    assert_eq!(timed.wait_closed().await, CliError::TimedOut);
    let mut survivor = OwnedCliTransport::spawn(mock.config("echo")).await.unwrap();
    let mut flood = OwnedCliTransport::spawn(mock.config("flood"))
        .await
        .unwrap();
    assert_ne!(survivor.process_id(), flood.process_id());
    // No receive: fill the bounded output queue. Cancellation must still finish.
    tokio::time::sleep(Duration::from_millis(50)).await;
    flood.cancel();
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(1), flood.wait_closed())
            .await
            .unwrap(),
        CliError::Cancelled
    );
    survivor.send(&json!({"still":"alive"})).await.unwrap();
    assert_eq!(survivor.receive().await.unwrap(), json!({"still":"alive"}));
    survivor.cancel();
    survivor.wait_closed().await;
}
#[tokio::test]
async fn configuration_has_no_search_shell_or_ambient_fallback() {
    let mock = Mock::new();
    let mut c = mock.config("echo");
    c.executable = PathBuf::from("owned-mock");
    assert!(matches!(
        OwnedCliTransport::spawn(c).await,
        Err(CliError::InvalidConfiguration)
    ));
    let mut c = mock.config("echo");
    c.executable = mock.root.join("not-installed");
    assert!(matches!(
        OwnedCliTransport::spawn(c).await,
        Err(CliError::LaunchFailed)
    ));
}
