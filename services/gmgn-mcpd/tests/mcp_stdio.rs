//! A real MCP session over a real stdio pipe, against a fake `gmgn-taskd`.
//!
//! This is the "can the agent actually read it and call it" judgement, expressed
//! as a test instead of a screenshot: the crate's own binary is spawned, spoken
//! to in newline-delimited JSON-RPC, and its answers are compared against the
//! bytes the fake authority returned.
//!
//! What each case is defending:
//!
//! * the read-only contract's payload is the authority's bytes, not a summary
//!   this face re-typed (`..._is_the_authoritys_own_bytes`);
//! * a tool that cannot know what the caller wants answers on the **success**
//!   channel (`insufficient_input_is_a_successful_call`);
//! * the authority's error codes come back with their own names
//!   (`authority_error_codes_are_not_renamed`);
//! * action tools are shut until a round arms them
//!   (`action_tools_refuse_without_an_armed_grant`);
//! * `tools/list` and the tool catalog this build ships cannot disagree
//!   (`tools_list_matches_the_shipped_catalog`).

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader as TokioBufReader};
use tokio::net::UnixListener;

const CONTRACT_CANARY: &str = "AUTHORITY-CONTRACT-CANARY-9f3a";
const SNAPSHOT_CANARY: &str = "AUTHORITY-SNAPSHOT-CANARY-4b71";
const READ_TIMEOUT: Duration = Duration::from_secs(30);

/// What the fake authority saw, so a test can prove the MCP face sent exactly
/// what it was given and invented nothing.
#[derive(Default)]
struct Seen {
    requests: Mutex<Vec<(String, Value)>>,
}

impl Seen {
    fn record(&self, method: &str, params: &Value) {
        self.requests
            .lock()
            .unwrap()
            .push((method.to_owned(), params.clone()));
    }

    fn last(&self, method: &str) -> Option<Value> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .rev()
            .find(|(name, _)| name == method)
            .map(|(_, params)| params.clone())
    }

    fn count(&self, method: &str) -> usize {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .filter(|(name, _)| name == method)
            .count()
    }
}

/// The fake daemon: same framing, same envelope, same error shape as
/// `services/gmgn-taskd/src/daemon.rs` (`{"id":..,"error":{"code":..,"message":..}}`).
fn spawn_authority(socket: PathBuf, seen: Arc<Seen>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let listener = UnixListener::bind(&socket).unwrap();
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let seen = seen.clone();
                tokio::spawn(async move {
                    let (read_half, mut write_half) = stream.into_split();
                    let mut reader = TokioBufReader::new(read_half);
                    let mut line = String::new();
                    while reader.read_line(&mut line).await.unwrap_or(0) > 0 {
                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            line.clear();
                            continue;
                        }
                        let request: Value = serde_json::from_str(trimmed).unwrap();
                        let id = request["id"].clone();
                        let method = request["method"].as_str().unwrap_or("").to_owned();
                        let params = request["params"].clone();
                        // The authority's own rule, enforced here too
                        // (`services/gmgn-taskd/src/daemon.rs`): the request id is a
                        // 1..=200 byte **string**. A peer that accepted a number
                        // would let a numeric id pass this test and then be refused
                        // by the real daemon — which is exactly what the first live
                        // end-to-end run hit.
                        let id_is_valid = request["id"]
                            .as_str()
                            .is_some_and(|value| (1..=200).contains(&value.len()));
                        if !id_is_valid {
                            let mut bytes = serde_json::to_vec(&json!({
                                "id": null,
                                "error": {"code": "invalid_request_id", "message": "invalid_request_id"},
                            }))
                            .unwrap();
                            bytes.push(b'\n');
                            if write_half.write_all(&bytes).await.is_err() {
                                return;
                            }
                            line.clear();
                            continue;
                        }
                        seen.record(&method, &params);
                        let reply = match method.as_str() {
                            "capability_contract" => json!({
                                "id": id,
                                "result": {
                                    "authority": "gmgn-taskd",
                                    "canary": CONTRACT_CANARY,
                                    "size_intent": {
                                        "axes": ["longest", "height"],
                                        "sources": ["user", "suggested", "default"],
                                        "min_meters": 0.01,
                                        "max_meters": 3.0,
                                    },
                                },
                            }),
                            "world_snapshot" => json!({
                                "id": id,
                                "result": {
                                    "record": {
                                        "recordRevision": 7,
                                        "boundarySeq": 12,
                                        "canary": SNAPSHOT_CANARY,
                                        "objects": [{"objectID": "wish-prop-1", "revision": 3}],
                                        "state": {
                                            "objectStates": {
                                                "wish-prop-1": {
                                                    "isEnabled": true,
                                                    "transform": {"position": {"x": 1, "y": 0.5, "z": 2}},
                                                    "metadata": {"gmgn.attachment.v1": {"slot": "back"}},
                                                },
                                            },
                                        },
                                    },
                                },
                            }),
                            "submit" => {
                                if params["name"] == "会过期的意图" {
                                    json!({"id": id, "error": {
                                        "code": "invalid_size_intent",
                                        "message": "invalid_size_intent",
                                    }})
                                } else {
                                    json!({"id": id, "result": {"job": {"id": params["id"]}}})
                                }
                            }
                            "snapshot" => json!({"id": id, "result": {"jobs": []}}),
                            "world_commit" => json!({"id": id, "result": {
                                "revision": 4, "replayed": false,
                            }}),
                            other => json!({"id": id, "error": {
                                "code": "unknown_method",
                                "message": other,
                            }}),
                        };
                        let mut bytes = serde_json::to_vec(&reply).unwrap();
                        bytes.push(b'\n');
                        if write_half.write_all(&bytes).await.is_err() {
                            return;
                        }
                    }
                });
            }
        });
    })
}

/// One spawned `gmgn-mcpd`, spoken to over stdio.
struct Session {
    child: Child,
    stdin: ChildStdin,
    replies: Receiver<Value>,
    next_id: u64,
}

impl Session {
    fn start(socket: &Path, grant: Option<&Path>) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_gmgn-mcpd"));
        command
            .arg("--socket")
            .arg(socket)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        if let Some(grant) = grant {
            command.arg("--grant").arg(grant);
        }
        let mut child = command.spawn().expect("gmgn-mcpd must start");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, replies) = mpsc::channel();
        // A reader thread with a channel gives every read a deadline, so a
        // wedged server fails the test instead of hanging the suite.
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { return };
                if line.trim().is_empty() {
                    continue;
                }
                if let Ok(value) = serde_json::from_str::<Value>(&line) {
                    if sender.send(value).is_err() {
                        return;
                    }
                }
            }
        });
        let mut session = Self {
            child,
            stdin,
            replies,
            next_id: 1,
        };
        session.handshake();
        session
    }

    fn send(&mut self, message: Value) {
        let mut bytes = serde_json::to_vec(&message).unwrap();
        bytes.push(b'\n');
        self.stdin.write_all(&bytes).unwrap();
        self.stdin.flush().unwrap();
    }

    fn read(&self) -> Value {
        self.replies
            .recv_timeout(READ_TIMEOUT)
            .expect("gmgn-mcpd must answer within the deadline")
    }

    fn handshake(&mut self) {
        self.send(json!({
            "jsonrpc": "2.0",
            "id": self.next_id,
            "method": "initialize",
            "params": {
                // rmcp pins the handshake itself to the newest version that
                // still carries `initialize` (`ProtocolVersion::LATEST_WITH_INITIALIZE`).
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "gmgn-mcpd-test", "version": "0.1.0"},
            },
        }));
        let id = self.next_id;
        self.next_id += 1;
        let reply = self.read();
        assert_eq!(reply["id"], json!(id), "initialize reply id");
        assert_eq!(
            reply["result"]["serverInfo"]["name"], "gmgn-mcpd",
            "the server must identify itself: {reply}"
        );
        assert!(
            reply["result"]["capabilities"]["tools"].is_object(),
            "the server must advertise the tools capability: {reply}"
        );
        self.send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        }));
        loop {
            let reply = self.read();
            if reply.get("id") == Some(&json!(id)) {
                return reply;
            }
            // A notification that is not ours must not be mistaken for a reply.
        }
    }

    fn call(&mut self, tool: &str, arguments: Value) -> Value {
        self.request(
            "tools/call",
            json!({"name": tool, "arguments": arguments}),
        )
    }

    fn stop(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct Fixture {
    root: PathBuf,
    socket: PathBuf,
    seen: Arc<Seen>,
}

impl Fixture {
    fn new(label: &str) -> Self {
        // Deliberately short: a unix socket path must fit in `sun_path`
        // (104 bytes on macOS), and `TMPDIR` on this machine is already long.
        static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let root = std::path::PathBuf::from(format!(
            "/tmp/gmgnmcpd-{}-{n}-{}",
            std::process::id(),
            &label[..label.len().min(8)]
        ));
        std::fs::create_dir_all(&root).unwrap();
        let socket = root.join("t.sock");
        let seen = Arc::new(Seen::default());
        spawn_authority(socket.clone(), seen.clone());
        // Wait for the listener to exist rather than sleeping a fixed amount.
        for _ in 0..300 {
            if socket.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(socket.exists(), "fake authority must bind {}", socket.display());
        Self { root, socket, seen }
    }

    fn grant(&self, state: &str, tools: &[&str]) -> PathBuf {
        let path = self.root.join("gmgn-host-tools.grant.json");
        let body = json!({
            "state": state,
            "socketPath": self.socket.display().to_string(),
            "secret": "not-used-by-the-mcp-face",
            "tools": tools.iter().map(|name| json!({"name": name})).collect::<Vec<_>>(),
        });
        std::fs::write(&path, serde_json::to_vec(&body).unwrap()).unwrap();
        path
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn result_of(reply: &Value) -> &Value {
    &reply["result"]["structuredContent"]
}

#[test]
fn a_real_session_lists_reads_and_refuses_honestly() {
    let fixture = Fixture::new("session");
    // Armed for the one action this session is allowed to take. Everything else
    // the session does is a read, which never consults the grant.
    let grant = fixture.grant("armed", &["gmgn_prop_submit"]);
    let mut session = Session::start(&fixture.socket, Some(&grant));

    // ── 1. tools/list is non-empty, namespaced, and equals the shipped catalog.
    let listed = session.request("tools/list", json!({}));
    let names: Vec<String> = listed["result"]["tools"]
        .as_array()
        .expect("tools/list must return an array")
        .iter()
        .map(|tool| tool["name"].as_str().unwrap().to_owned())
        .collect();
    assert!(names.len() >= 8, "expected a real tool face, got {names:?}");
    for name in &names {
        assert!(name.starts_with("gmgn_"), "{name} is not namespaced");
    }
    for required in [
        "gmgn_capability_contract",
        "gmgn_world_read",
        "gmgn_world_commit",
        "gmgn_prop_submit",
        "gmgn_prop_cancel",
        "gmgn_prop_retry",
    ] {
        assert!(names.contains(&required.to_owned()), "missing {required}");
    }
    for tool in listed["result"]["tools"].as_array().unwrap() {
        assert!(
            tool["description"].as_str().is_some_and(|text| !text.is_empty()),
            "{tool} has no description"
        );
        assert_eq!(tool["inputSchema"]["type"], "object", "{tool}");
    }

    // ── 2. The read-only contract is the authority's own bytes. The canary is a
    //       field only the authority knows; if this face re-typed the contract,
    //       the canary would be gone.
    let contract = session.call("gmgn_capability_contract", json!({}));
    assert_eq!(contract["result"]["isError"], json!(false), "{contract}");
    let payload = result_of(&contract);
    assert_eq!(payload["ok"], json!(true));
    assert_eq!(payload["authority"], json!("gmgn-taskd"));
    assert_eq!(
        payload["contract"]["canary"],
        json!(CONTRACT_CANARY),
        "RAW={contract}"
    );
    assert_eq!(
        payload["contract"]["size_intent"]["max_meters"],
        json!(3.0)
    );
    // The MCP block is generated from the same catalog `tools/list` used.
    let advertised: Vec<String> = payload["mcp"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(advertised, names, "the contract must advertise the served tools");
    assert_eq!(payload["mcp"]["naming"], json!("tools appear to the client as mcp__gmgn__<tool>"));

    // ── 3. A world read carries the authoritative snapshot byte for byte, and
    //       the face sent the caller's arguments unembellished.
    let snapshot = session.call("gmgn_world_read", json!({"worldID": "living-cabin"}));
    assert_eq!(snapshot["result"]["isError"], json!(false), "{snapshot}");
    let payload = result_of(&snapshot);
    assert_eq!(payload["result"]["record"]["canary"], json!(SNAPSHOT_CANARY));
    assert_eq!(
        payload["result"]["record"]["state"]["objectStates"]["wish-prop-1"]["metadata"]
            ["gmgn.attachment.v1"]["slot"],
        json!("back"),
        "the attachment slot must survive the trip verbatim"
    );
    assert_eq!(
        fixture.seen.last("world_snapshot"),
        Some(json!({"worldID": "living-cabin"})),
        "the face must not add fields the caller did not give"
    );

    // ── 4. "I need a size" answers on the SUCCESS channel with the published
    //       vocabulary. It is not an error: the call did exactly what it should.
    let asked = session.call(
        "gmgn_prop_submit",
        json!({
            "jobID": "11111111-2222-4333-8444-555555555555",
            "endpoint": "https://generator.test",
            "name": "白色长剑",
            "pngBase64": "aGk=",
            "source": {"author": "resident", "license": "CC0"},
        }),
    );
    assert_eq!(
        asked["result"]["isError"],
        json!(false),
        "信息不足必须走成功通道：{asked}"
    );
    let payload = result_of(&asked);
    assert_eq!(payload["ok"], json!(false));
    assert_eq!(payload["code"], json!("insufficient_input"));
    assert_eq!(payload["needs"], json!(["size_axis", "size_meters"]));
    assert_eq!(
        payload["pending_id"],
        json!("11111111-2222-4333-8444-555555555555")
    );
    assert!(
        payload["question"].as_str().is_some_and(|text| text.contains("多大")),
        "the question must be askable: {payload}"
    );
    assert_eq!(
        payload["size_intent"]["max_meters"],
        json!(3.0),
        "the question must quote the authority's own range"
    );
    assert_eq!(
        fixture.seen.count("submit"),
        0,
        "an under-specified submit must not reach the authority"
    );

    // ── 4b. A `longest` intent is not "how big?" — that question is already
    //        answered, so the receipt asks for the one thing actually missing
    //        rather than repeating a canned prompt.
    let longest_only = session.call(
        "gmgn_prop_submit",
        json!({
            "jobID": "44444444-2222-4333-8444-555555555555",
            "endpoint": "https://generator.test",
            "name": "白色长剑",
            "pngBase64": "aGk=",
            "source": {"author": "resident", "license": "CC0"},
            "sizeIntent": {"axis": "longest", "meters": 1.1, "source": "user"},
        }),
    );
    assert_eq!(longest_only["result"]["isError"], json!(false), "{longest_only}");
    let payload = result_of(&longest_only);
    assert_eq!(payload["code"], json!("insufficient_input"));
    assert_eq!(payload["needs"], json!(["height_meters"]));
    assert!(
        payload["question"].as_str().is_some_and(|text| text.contains("heightMeters")),
        "{payload}"
    );
    assert_eq!(fixture.seen.count("submit"), 0);

    // ── 5. Resuming with the returned pending_id reuses the same job id, drives
    //       heightMeters from the height intent, and passes the intent through
    //       untouched.
    let submitted = session.call(
        "gmgn_prop_submit",
        json!({
            "jobID": "99999999-2222-4333-8444-555555555555",
            "endpoint": "https://generator.test",
            "name": "白色长剑",
            "pngBase64": "aGk=",
            "source": {"author": "resident", "license": "CC0"},
            "pendingID": "11111111-2222-4333-8444-555555555555",
            "sizeIntent": {"axis": "height", "meters": 1.1, "source": "user"},
        }),
    );
    assert_eq!(submitted["result"]["isError"], json!(false), "{submitted}");
    let sent_to_authority = fixture.seen.last("submit").expect("submit must reach the authority");
    assert_eq!(
        sent_to_authority["id"],
        json!("11111111-2222-4333-8444-555555555555"),
        "a resume must reuse the original idempotency key"
    );
    assert_eq!(sent_to_authority["heightMeters"], json!(1.1));
    assert_eq!(
        sent_to_authority["sizeIntent"],
        json!({"axis": "height", "meters": 1.1, "source": "user"}),
        "the intent must reach the authority unmodified"
    );
    assert!(
        sent_to_authority.get("jobID").is_none() && sent_to_authority.get("pendingID").is_none(),
        "the MCP-only bookkeeping keys must not be forwarded: {sent_to_authority}"
    );

    // ── 6. An authority rejection keeps the authority's own code.
    let rejected = session.call(
        "gmgn_prop_submit",
        json!({
            "jobID": "22222222-2222-4333-8444-555555555555",
            "endpoint": "https://generator.test",
            "name": "会过期的意图",
            "pngBase64": "aGk=",
            "source": {"author": "resident", "license": "CC0"},
            "heightMeters": 0.2,
            "sizeIntent": {"axis": "width", "meters": 1.1, "source": "user"},
        }),
    );
    assert_eq!(rejected["result"]["isError"], json!(true), "{rejected}");
    assert_eq!(result_of(&rejected)["code"], json!("invalid_size_intent"));
    assert_eq!(result_of(&rejected)["message"], json!("invalid_size_intent"));

    // ── 7. An action tool this round did not name is shut; the read-only face
    //       keeps working in the same session, because reading is never gated.
    let commit = session.call(
        "gmgn_world_commit",
        json!({
            "worldID": "living-cabin", "requestID": "r-1", "expectedRevision": 0,
            "ops": [{"op": "setWorldFacts", "facts": {"weather": "clear"}}],
        }),
    );
    assert_eq!(commit["result"]["isError"], json!(true), "{commit}");
    assert_eq!(result_of(&commit)["code"], json!("mcp_tool_not_granted"));
    assert_eq!(
        fixture.seen.count("world_commit"),
        0,
        "a refused action must never reach the authority"
    );
    assert_eq!(
        session.call("gmgn_capability_contract", json!({}))["result"]["isError"],
        json!(false),
        "read-only tools must not depend on a grant"
    );

    // ── 8. An unknown tool is reported, not silently accepted.
    let unknown = session.call("gmgn_not_a_tool", json!({}));
    assert_eq!(unknown["result"]["isError"], json!(true));
    assert_eq!(result_of(&unknown)["code"], json!("unknown_tool"));

    session.stop();
}

#[test]
fn a_process_with_no_grant_reads_freely_and_acts_never() {
    // The shipped default: no grant document at all. Reads work, every action
    // refuses and says which refusal it is. An MCP server that acts on the world
    // whenever it happens to be reachable is the shape this design removes.
    let fixture = Fixture::new("no-grant");
    let mut session = Session::start(&fixture.socket, None);

    assert_eq!(
        session.call("gmgn_world_read", json!({"worldID": "w"}))["result"]["isError"],
        json!(false)
    );
    for tool in ["gmgn_world_commit", "gmgn_prop_cancel", "gmgn_prop_retry"] {
        let arguments = match tool {
            "gmgn_world_commit" => json!({
                "worldID": "w", "requestID": "r", "expectedRevision": 0,
                "ops": [{"op": "setWorldFacts", "facts": {}}],
            }),
            _ => json!({"id": "11111111-2222-4333-8444-555555555555"}),
        };
        let refused = session.call(tool, arguments);
        assert_eq!(refused["result"]["isError"], json!(true), "{tool}: {refused}");
        assert_eq!(
            result_of(&refused)["code"],
            json!("mcp_grant_not_configured"),
            "{tool}"
        );
    }
    assert_eq!(fixture.seen.count("world_commit"), 0);
    assert_eq!(fixture.seen.count("cancel"), 0);
    assert_eq!(fixture.seen.count("retry"), 0);
}

#[test]
fn an_armed_round_opens_exactly_the_tools_it_names() {
    let fixture = Fixture::new("grant");
    let grant = fixture.grant("armed", &["gmgn_world_commit"]);
    let mut session = Session::start(&fixture.socket, Some(&grant));

    // Armed for this one tool: it goes through.
    let commit = session.call(
        "gmgn_world_commit",
        json!({
            "worldID": "living-cabin", "requestID": "r-2", "expectedRevision": 3,
            "ops": [{"op": "setWorldFacts", "facts": {"weather": "clear"}}],
        }),
    );
    assert_eq!(commit["result"]["isError"], json!(false), "{commit}");
    let sent = fixture.seen.last("world_commit").expect("commit must reach the authority");
    assert_eq!(sent["expectedRevision"], json!(3));
    assert_eq!(sent["ops"][0]["op"], json!("setWorldFacts"));

    // Armed, but not for this name.
    let submit = session.call(
        "gmgn_prop_submit",
        json!({
            "jobID": "33333333-2222-4333-8444-555555555555",
            "endpoint": "https://generator.test", "name": "灯",
            "pngBase64": "aGk=", "source": {"author": "a", "license": "l"},
            "heightMeters": 0.4,
        }),
    );
    assert_eq!(submit["result"]["isError"], json!(true), "{submit}");
    assert_eq!(result_of(&submit)["code"], json!("mcp_tool_not_granted"));
    assert_eq!(fixture.seen.count("submit"), 0);
}

#[test]
fn a_grant_for_another_daemon_is_refused() {
    let fixture = Fixture::new("foreign-grant");
    let path = fixture.root.join("foreign.grant.json");
    std::fs::write(
        &path,
        serde_json::to_vec(&json!({
            "state": "armed",
            "socketPath": "/tmp/some-other-private-root/taskd.sock",
            "tools": [{"name": "gmgn_world_commit"}],
        }))
        .unwrap(),
    )
    .unwrap();
    let mut session = Session::start(&fixture.socket, Some(&path));
    let commit = session.call(
        "gmgn_world_commit",
        json!({"worldID": "w", "requestID": "r", "expectedRevision": 0,
               "ops": [{"op": "setWorldFacts", "facts": {}}]}),
    );
    assert_eq!(result_of(&commit)["code"], json!("mcp_grant_socket_mismatch"));
    assert_eq!(fixture.seen.count("world_commit"), 0);
}

#[test]
fn tools_list_matches_the_shipped_catalog() {
    // Two independent paths to the same definitions: the live MCP handshake and
    // the `--list-tools` self-report. They cannot disagree, and neither is a
    // hand-maintained copy in this test.
    let fixture = Fixture::new("catalog");
    let mut session = Session::start(&fixture.socket, None);
    let listed = session.request("tools/list", json!({}));
    let live: BTreeMap<String, Value> = listed["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| (tool["name"].as_str().unwrap().to_owned(), tool.clone()))
        .collect();

    let output = Command::new(env!("CARGO_BIN_EXE_gmgn-mcpd"))
        .arg("--list-tools")
        .output()
        .unwrap();
    assert!(output.status.success());
    let reported: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(reported["count"], json!(live.len()));
    for tool in reported["tools"].as_array().unwrap() {
        let name = tool["name"].as_str().unwrap();
        let served = live.get(name).unwrap_or_else(|| panic!("{name} not served"));
        assert_eq!(served["inputSchema"], tool["inputSchema"], "{name} schema");
        assert_eq!(served["description"], tool["description"], "{name} description");
    }
}

#[test]
fn the_server_starts_without_an_authority_and_says_so() {
    // A dead authority must produce a named, visible failure — never a silent
    // empty success that the agent would read as "there are no props".
    let fixture = Fixture::new("dead-authority");
    let missing = fixture.root.join("nothing-here.sock");
    let mut session = Session::start(&missing, None);
    let contract = session.call("gmgn_capability_contract", json!({}));
    assert_eq!(contract["result"]["isError"], json!(true), "{contract}");
    assert_eq!(result_of(&contract)["code"], json!("authority_unavailable"));
}
