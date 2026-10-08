#![cfg(unix)]
use gmgn_agent_runtime::{
    oneshot_transport::{run, OneshotConfig, OneshotError, MAX_STREAM_BYTES},
    CancellationToken,
};
use std::os::unix::fs::PermissionsExt;
use std::{
    collections::BTreeMap,
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
static SEQUENCE: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new(body: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "gmgn-oneshot-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&dir).unwrap();
        fs::write(dir.join("mock"), format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(dir.join("mock"), fs::Permissions::from_mode(0o700)).unwrap();
        Self(dir)
    }
    fn config(&self) -> OneshotConfig {
        OneshotConfig {
            executable: self.0.join("mock"),
            arguments: vec![],
            environment: BTreeMap::new(),
            working_directory: Some(self.0.clone()),
            lifetime: Duration::from_secs(5),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[tokio::test]
async fn raw_stdin_eof_whole_json_and_real_nonzero_exit() {
    let f = Fixture::new("IFS= read -r text\nprintf '{\"result\":\"%s\"}' \"$text\"\nexit 7");
    let out = run(f.config(), "raw prompt".into(), CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(out.stdout, "{\"result\":\"raw prompt\"}");
    assert_eq!(out.status.code(), Some(7));
}
#[tokio::test]
async fn utf8_and_input_budget_fail_closed() {
    let f = Fixture::new("printf '\\377'");
    assert_eq!(
        run(f.config(), String::new(), CancellationToken::new())
            .await
            .unwrap_err(),
        OneshotError::InvalidUtf8
    );
    assert_eq!(
        run(
            f.config(),
            "a".repeat(MAX_STREAM_BYTES + 1),
            CancellationToken::new()
        )
        .await
        .unwrap_err(),
        OneshotError::InputTooLarge
    );
}
#[tokio::test]
async fn independent_stdout_stderr_caps() {
    for (redirect, expected) in [
        ("", OneshotError::StdoutTooLarge),
        (" >&2", OneshotError::StderrTooLarge),
    ] {
        let body=format!("chunk='{}'\ni=0\nwhile [ $i -lt 4097 ]; do printf '%s' \"$chunk\"{redirect}; i=$((i+1)); done", "x".repeat(1024));
        let f = Fixture::new(&body);
        assert_eq!(
            run(f.config(), String::new(), CancellationToken::new())
                .await
                .unwrap_err(),
            expected
        );
    }
    let f = Fixture::new("printf 'private secret stderr' >&2\nprintf 'public result'");
    assert_eq!(
        run(f.config(), String::new(), CancellationToken::new())
            .await
            .unwrap()
            .stdout,
        "public result"
    );
}
#[tokio::test]
async fn deadline_and_cancel_reap_private_launcher_descendants() {
    for cancel_now in [false, true] {
        let f = Fixture::new(
            "trap 'wait; exit 0' TERM\n/bin/sh -c 'echo $$ > child.pid; while :; do :; done' &\nchild=$!\necho $$ > leader.pid\nwhile [ ! -s child.pid ]; do :; done\nprintf '%s %s\\n' \"$$\" \"$child\" > ready.tmp\n/bin/mv ready.tmp ready\nwait",
        );
        let token = CancellationToken::new();
        let mut config = f.config();
        // The original 500ms deadline raced the 500ms polling window under
        // parallel build load. The fixture now publishes both live identities
        // atomically before the test may assert cancellation/reclamation.
        config.lifetime = Duration::from_secs(5);
        let task = tokio::spawn(run(config, String::new(), token.clone()));
        let ready = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if let Ok(ready) = fs::read_to_string(f.0.join("ready")) {
                    break ready;
                }
                assert!(
                    !task.is_finished(),
                    "private launcher terminated before ready barrier"
                );
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("private launcher did not reach ready barrier before test deadline");
        let pids: Vec<i32> = ready
            .split_whitespace()
            .map(|pid| pid.parse().unwrap())
            .collect();
        assert_eq!(pids.len(), 2);
        let (leader, child) = (pids[0], pids[1]);
        assert_eq!(unsafe { libc::kill(leader, 0) }, 0);
        assert_eq!(unsafe { libc::kill(child, 0) }, 0);
        if cancel_now {
            token.cancel();
        }
        assert_eq!(
            task.await.unwrap().unwrap_err(),
            if cancel_now {
                OneshotError::Cancelled
            } else {
                OneshotError::TimedOut
            }
        );
        assert_eq!(unsafe { libc::kill(leader, 0) }, -1);
        // TERM lets the launcher reap its child; allow init a bounded reap window.
        for _ in 0..100 {
            if unsafe { libc::kill(child, 0) } == -1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(unsafe { libc::kill(child, 0) }, -1);
    }
}
