use serde_json::Value;
use std::{io::{Read, Write}, net::{Ipv4Addr, SocketAddrV4, TcpStream}, sync::mpsc, time::Duration};

pub struct SettingsTransport {
    pub commands: mpsc::Sender<Value>,
    pub updates: mpsc::Receiver<Result<Value, String>>,
}

pub fn start(path: &str) -> Result<SettingsTransport, String> {
    let bytes = std::fs::read(path).map_err(|_| "无法读取 Unity 设置连接，请从 Unity 重新打开设置。")?;
    if bytes.len() > 4096 { return Err("Unity 设置连接信息无效。".into()); }
    let marker: Value = serde_json::from_slice(&bytes).map_err(|_| "Unity 设置连接信息无效。")?;
    if marker["version"] != 1 || marker["host"] != "127.0.0.1" { return Err("Unity 设置连接信息无效。".into()); }
    let port = marker["port"].as_u64().filter(|p| (1..=65535).contains(p)).ok_or("Unity 设置端口无效。")? as u16;
    let token = marker["token"].as_str().filter(|v| !v.is_empty() && v.len() <= 256 && v.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')).ok_or("Unity 设置认证信息无效。")?.to_owned();
    let (sender, receiver) = mpsc::channel::<Value>();
    let (updates, events) = mpsc::channel();
    std::thread::spawn(move || {
        let mut supported = Value::Null;
        loop {
            match request(port, &token, "GET", "/snapshot", None).and_then(project_snapshot) {
                Ok(state) => { supported = state["supportedCommands"].clone(); if updates.send(Ok(state)).is_err() { break; } }
                Err(error) => { if updates.send(Err(error)).is_err() { break; } }
            }
            match receiver.recv_timeout(Duration::from_millis(250)) {
                Ok(command) => {
                    if !supported.as_array().is_some_and(|ops| ops.iter().any(|op| op == &command["op"])) {
                        if updates.send(Err("此功能尚未接入 Unity，原设置保持不变。".into())).is_err() { break; }
                        continue;
                    }
                    let result = request(port, &token, "POST", "/command", Some(&command));
                    match result {
                        Ok(value) if value["accepted"] == true => {}
                        Ok(_) => {
                            if updates.send(Err("Unity 没有接受这次设置。".into())).is_err() { break; }
                        }
                        Err(_) => {
                            // The command may have committed before its reply was lost.
                            // The next snapshot reads the authority; never replay the write.
                            if updates.send(Err("设置回执未收到，正在重新读取当前设置。".into())).is_err() { break; }
                        }
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
        }
    });
    Ok(SettingsTransport { commands: sender, updates: events })
}

fn request(port: u16, token: &str, method: &str, path: &str, value: Option<&Value>) -> Result<Value, String> {
    let failure = || "Unity 设置连接已断开，请关闭后从 Unity 重新打开。".to_owned();
    let mut stream = TcpStream::connect_timeout(&SocketAddrV4::new(Ipv4Addr::LOCALHOST, port).into(), Duration::from_secs(2)).map_err(|_| failure())?;
    stream.set_read_timeout(Some(response_timeout(method, path))).map_err(|_| failure())?;
    stream.set_write_timeout(Some(Duration::from_secs(2))).map_err(|_| failure())?;
    let body = value.map(Value::to_string).unwrap_or_default();
    let header = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
    stream.write_all(header.as_bytes()).and_then(|_| stream.write_all(body.as_bytes())).map_err(|_| failure())?;
    let mut bytes = Vec::new(); stream.take(256 * 1024 + 1).read_to_end(&mut bytes).map_err(|_| failure())?;
    if bytes.len() > 256 * 1024 { return Err(failure()); }
    let boundary = bytes.windows(4).position(|w| w == b"\r\n\r\n").ok_or_else(failure)?;
    let header = std::str::from_utf8(&bytes[..boundary]).map_err(|_| failure())?;
    if header.lines().next().and_then(|line| line.split_whitespace().nth(1)) != Some("200") { return Err(failure()); }
    serde_json::from_slice(&bytes[boundary + 4..]).map_err(|_| failure())
}

fn response_timeout(method: &str, path: &str) -> Duration {
    if method == "POST" && path == "/command" {
        Duration::from_secs(7)
    } else {
        Duration::from_secs(2)
    }
}

/// Every selected value and catalog comes from the live Unity host, never a
/// persisted ProductHost snapshot or a second settings authority.
pub fn project_snapshot(value: Value) -> Result<Value, String> {
    if value["version"] != 1 || !value["settings"].is_object() || !value["stage"].is_object() || !value["supportedCommands"].is_array() {
        return Err("Unity 设置接口版本不完整，请更新播放器与设置应用。".into());
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test] fn command_waits_for_authority_while_snapshot_remains_bounded() {
        assert_eq!(response_timeout("POST", "/command"), Duration::from_secs(7));
        assert_eq!(response_timeout("GET", "/snapshot"), Duration::from_secs(2));
        assert_eq!(response_timeout("POST", "/snapshot"), Duration::from_secs(2));
    }
    #[test] fn projection_uses_live_selection_and_catalog() {
        let input = json!({"version":1,"settings":{"agent":{"residentPersona":"真实设置"}},"supportedCommands":["agent.save"],"stage":{"player":{"lyricID":"monet_poster","lyrics":[{"id":"monet_poster","name":"莫奈"}],"clouds":[{"id":"orbitalShell","name":"星球"}],"cloudID":"orbitalShell","particleScale":1.2}}});
        let state = project_snapshot(input.clone()).unwrap();
        assert_eq!(state, input);
        assert_eq!(state["stage"]["player"]["lyricID"], "monet_poster");
        assert_eq!(state["settings"]["agent"]["residentPersona"], "真实设置");
        assert_eq!(state["stage"]["player"]["cloudID"], "orbitalShell");
        assert_eq!(state["stage"]["player"]["lyrics"][0]["name"], "莫奈");
    }
    #[test] fn incomplete_host_cannot_fabricate_settings() {
        assert!(project_snapshot(json!({"lyricVisual":{"configuredMode":"monet_poster"}})).is_err());
    }
    #[test] fn http_contract_authenticates_and_reads_actual_response() {
        let server = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = server.local_addr().unwrap().port();
        let task = std::thread::spawn(move || {
            let (mut client, _) = server.accept().unwrap();
            let mut header = Vec::new();
            loop { let mut byte = [0]; client.read_exact(&mut byte).unwrap(); header.push(byte[0]); if header.ends_with(b"\r\n\r\n") { break; } }
            let text = String::from_utf8(header).unwrap();
            assert!(text.starts_with("POST /command HTTP/1.1\r\n"));
            assert!(text.contains("Authorization: Bearer private-test-token\r\n"));
            let length: usize = text.lines().find_map(|row| row.strip_prefix("Content-Length: ")).unwrap().parse().unwrap();
            let mut body = vec![0; length]; client.read_exact(&mut body).unwrap();
            assert_eq!(serde_json::from_slice::<Value>(&body).unwrap()["id"], "monet_poster");
            let body = b"{\"accepted\":true}";
            let header = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
            client.write_all(header.as_bytes()).unwrap(); client.write_all(body).unwrap();
        });
        assert_eq!(request(port, "private-test-token", "POST", "/command", Some(&json!({"op":"stage.player.lyrics", "id":"monet_poster"}))).unwrap()["accepted"], true);
        task.join().unwrap();
    }
    #[test] fn delayed_command_receipt_is_read_without_replaying_write() {
        let server = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = server.local_addr().unwrap().port();
        let task = std::thread::spawn(move || {
            let (mut client, _) = server.accept().unwrap();
            let mut header = Vec::new();
            loop {
                let mut byte = [0];
                client.read_exact(&mut byte).unwrap();
                header.push(byte[0]);
                if header.ends_with(b"\r\n\r\n") { break; }
            }
            let text = String::from_utf8(header).unwrap();
            let length: usize = text.lines().find_map(|row| row.strip_prefix("Content-Length: ")).unwrap().parse().unwrap();
            let mut body = vec![0; length];
            client.read_exact(&mut body).unwrap();
            assert_eq!(serde_json::from_slice::<Value>(&body).unwrap()["op"], "agent.backend");
            // A real response beyond the former two-second timeout.
            std::thread::sleep(Duration::from_millis(2200));
            client.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 17\r\nConnection: close\r\n\r\n{\"accepted\":true}").unwrap();
        });
        assert_eq!(request(port, "private-test-token", "POST", "/command", Some(&json!({"op":"agent.backend","id":"codex"}))).unwrap()["accepted"], true);
        task.join().unwrap();
    }
}
