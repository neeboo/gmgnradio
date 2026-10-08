//! "Killing the MCP process must not touch the authority", made checkable.
//!
//! The claim is structural, not a matter of timing: `gmgn-mcpd` cannot hold the
//! authority's state because it never opens it. `gmgn-taskd` keeps its world in
//! a SQLite database under a private root guarded by an exclusive portable lock.
//! Its only supported way in is the authenticated loopback endpoint it owns.
//!
//! This test fails the moment somebody gives the MCP process a direct path in —
//! a database handle, the lock, or the storage crate. That is the injection this
//! judgement is aimed at: an MCP server that writes the database itself would
//! make an MCP client restart able to corrupt or outlive the authority, and would
//! also mean the tools are no longer "the daemon's methods with a public face"
//! but a second writer.

use std::path::PathBuf;

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn source_files() -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect(&crate_root().join("src"), &mut files);
    files
}

fn test_files() -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect(&crate_root().join("tests"), &mut files);
    files
}

fn collect(directory: &std::path::Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect(&path, files);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            files.push(path);
        }
    }
}

fn read_all(paths: Vec<PathBuf>) -> Vec<(PathBuf, String)> {
    paths
        .into_iter()
        .map(|path| {
            let text = std::fs::read_to_string(&path).unwrap();
            (path, text)
        })
        .collect()
}

/// Drop `//` line comments before scanning.
///
/// The sources are *allowed* — required, even — to explain in prose why this
/// process does not link the storage engine or take the daemon's lock. What they
/// may not do is mention those as code. A `//` preceded by `:` is kept, so a URL
/// in a doc comment does not truncate the line it sits on.
fn without_comments(text: &str) -> String {
    text.lines()
        .map(|line| {
            let bytes = line.as_bytes();
            let mut index = 0;
            while let Some(at) = line[index..].find("//") {
                let absolute = index + at;
                if absolute > 0 && bytes[absolute - 1] == b':' {
                    index = absolute + 2;
                    continue;
                }
                return &line[..absolute];
            }
            line
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The shipped sources, comments stripped.
fn scanned_sources() -> Vec<(PathBuf, String)> {
    read_all(source_files())
        .into_iter()
        .map(|(path, text)| (path, without_comments(&text)))
        .collect()
}

/// Exclude only explicitly test-gated modules, preserving any production code
/// after their closing brace. Strings (including Rust raw strings) cannot hide it.
fn skip_non_code(text: &str, at: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    if bytes[at..].starts_with(b"//") {
        return Some(
            text[at..]
                .find('\n')
                .map(|n| at + n + 1)
                .unwrap_or(bytes.len()),
        );
    }
    if bytes[at..].starts_with(b"/*") {
        let mut index = at + 2;
        let mut depth = 1;
        while depth > 0 {
            assert!(index < bytes.len(), "block comment closes");
            if bytes[index..].starts_with(b"/*") {
                depth += 1;
                index += 2;
            } else if bytes[index..].starts_with(b"*/") {
                depth -= 1;
                index += 2;
            } else {
                index += 1;
            }
        }
        return Some(index);
    }
    if bytes[at] == b'r' {
        let mut quote = at + 1;
        while bytes.get(quote) == Some(&b'#') {
            quote += 1;
        }
        if bytes.get(quote) == Some(&b'"') {
            let ending = format!("\"{}", "#".repeat(quote - at - 1));
            return Some(
                quote
                    + 1
                    + text[quote + 1..].find(&ending).expect("raw string closes")
                    + ending.len(),
            );
        }
    }
    if bytes[at] == b'\'' {
        // A character/byte character has exactly one scalar or escape; a
        // lifetime such as 'static has no immediate closing quote and stays code.
        let start = at + 1;
        let end = if bytes.get(start) == Some(&b'\\') {
            match bytes.get(start + 1) {
                Some(b'x') => start + 4,
                Some(b'u') if bytes.get(start + 2) == Some(&b'{') => {
                    start + 3 + text[start + 3..].find('}').expect("unicode escape closes") + 1
                }
                Some(_) => start + 2,
                None => return None,
            }
        } else {
            start + text[start..].chars().next()?.len_utf8()
        };
        if bytes.get(end) == Some(&b'\'') {
            return Some(end + 1);
        }
    }
    if bytes[at] == b'"' {
        let mut index = at + 1;
        loop {
            match bytes.get(index) {
                Some(b'"') => return Some(index + 1),
                Some(b'\\') => index += 2,
                Some(_) => index += 1,
                None => panic!("ordinary string closes"),
            }
        }
    }
    None
}

fn without_test_modules(text: &str) -> String {
    let mut output = String::new();
    let mut cursor = 0;
    loop {
        let mut index = cursor;
        let mut marker = None;
        while index < text.len() {
            if let Some(end) = skip_non_code(text, index) {
                index = end;
                continue;
            }
            if let Some(m) = ["#[cfg(test)]", "#[cfg(all(test, unix))]"]
                .iter()
                .find(|m| text.as_bytes()[index..].starts_with(m.as_bytes()))
            {
                marker = Some((index, m.len()));
                break;
            }
            index += 1;
        }
        let Some((start, length)) = marker else {
            output.push_str(&text[cursor..]);
            break;
        };
        output.push_str(&text[cursor..start]);
        let rest = &text[start + length..];
        if !rest.trim_start().starts_with("mod tests") {
            output.push_str(&text[start..start + length]);
            cursor = start + length;
            continue;
        }
        let open = start + length + rest.find('{').expect("test module body");
        let bytes = text.as_bytes();
        let mut index = open + 1;
        let mut depth = 1;
        while depth > 0 {
            assert!(index < bytes.len(), "balanced test module");
            if let Some(end) = skip_non_code(text, index) {
                index = end;
                continue;
            }
            match bytes[index] {
                b'{' => depth += 1,
                b'}' => depth -= 1,
                _ => {}
            }
            index += 1;
        }
        cursor = index;
    }
    output
}

#[test]
fn test_peer_exclusion_does_not_hide_later_production_listeners() {
    let source = "fn before() {}\n#[cfg(test)]\nmod tests { fn peer() { let s=r#\"}\"#; TcpListener::bind(); } }\nfn after(){TcpListener::bind();}";
    let product = without_test_modules(source);
    assert!(!product.contains("fn peer"));
    assert!(product.contains("fn before"));
    assert!(product.contains("fn after(){TcpListener::bind();}"));
}

#[test]
fn test_peer_exclusion_handles_characters_comments_and_string_attributes() {
    let source = r####"fn before(){ let attr = "#[cfg(test)] mod tests {TcpListener::bind();}"; }
#[cfg(all(test, unix))]
mod tests {
    fn peer<'a>(s: &'a str) {
        let quote=b'"'; let brace=b'{'; let escaped='\''; let unicode='\u{7d}';
        let raw=r###"} \" {"###;
        /* unmatched } and " /* nested { */ */
        // unmatched } and "
        TcpListener::bind();
    }
}
fn after(){ TcpListener::bind(); }
"####;
    let product = without_test_modules(source);
    assert!(!product.contains("fn peer"));
    assert!(product.contains("let attr"));
    assert!(product.contains("fn after(){ TcpListener::bind(); }"));
}

#[test]
fn the_mcp_process_never_opens_the_authoritys_storage() {
    // Code-shaped tokens only: the sources are *allowed* to explain in prose why
    // they do not link the storage engine. What they may not do is mention it as
    // code, or name the authority's own private paths.
    let forbidden = [
        // The storage engine and the type that owns it.
        "rusqlite",
        "sqlite3",
        "sqlite_vec",
        "store::Database",
        "Database::open",
        // The exclusive lock on the private root.
        "taskd.lock",
        "try_lock_exclusive",
        "fs2::",
        // A path into the daemon's private root.
        "Application Support/gmgn radio",
        "prop-service",
    ];
    for (path, text) in scanned_sources() {
        for needle in forbidden {
            assert!(
                !text.contains(needle),
                "{} 里出现了 `{needle}`：MCP 进程一旦能直接碰权威存储，\
                 「杀掉 MCP 不影响权威」就不再成立。所有访问都必须走 taskd 的 HTTP。",
                path.display()
            );
        }
    }
}

#[test]
fn the_manifest_does_not_depend_on_the_storage_stack() {
    let manifest = std::fs::read_to_string(crate_root().join("Cargo.toml")).unwrap();
    for forbidden in ["rusqlite", "sqlite-vec", "fs2"] {
        assert!(
            !manifest.contains(forbidden),
            "gmgn-mcpd 的依赖里出现了 `{forbidden}`：它不该有能力直接碰权威存储"
        );
    }
    // HTTP client only; the MCP face remains a stdio server.
    assert!(manifest.contains("rmcp"));
    assert!(manifest.contains("reqwest"));
    for forbidden in ["hyper", "axum", "tiny_http", "warp"] {
        assert!(
            !manifest.contains(forbidden),
            "gmgn-mcpd 引入了 HTTP 服务栈 `{forbidden}`：仅允许 taskd 的 HTTP 客户端"
        );
    }
}

#[test]
fn unix_syscalls_are_limited_to_private_grant_and_catalog_reads() {
    // libc is not an authority transport: these three symbols only secure the
    // host's bounded 0600 grant/catalog reads against links, FIFOs and other owners.
    // Database dependencies and authority paths remain prohibited above.
    let allowed = ["geteuid", "O_NOFOLLOW", "O_NONBLOCK"];
    for (path, text) in scanned_sources() {
        if !text.contains("libc::") {
            continue;
        }
        assert_eq!(path.file_name().unwrap(), "resident_claude.rs");
        let start = text
            .find("fn private_read(")
            .expect("private-file boundary");
        let end = text[start..].find("struct ReadGrant").unwrap() + start;
        for (at, _) in text.match_indices("libc::") {
            assert!(
                (start..end).contains(&at),
                "syscalls may not escape private_read"
            );
            let name = text[at + "libc::".len()..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect::<String>();
            assert!(
                allowed.contains(&name.as_str()),
                "unapproved private-file syscall"
            );
        }
        let reader = &text[start..end];
        for required in [
            "metadata.is_file()",
            "metadata.mode() & 0o777 != 0o600",
            "parent.mode() & 0o777 != 0o700",
            "file.take((limit + 1) as u64)",
        ] {
            assert!(
                reader.contains(required),
                "private reads retain their type, permission and byte limits"
            );
        }
    }
}

#[test]
fn the_only_way_into_the_world_is_the_daemon_http_endpoint() {
    // Every world access in this crate goes through `taskd::Client`, and that
    // client has exactly one constructor and one call path.
    let client = std::fs::read_to_string(crate_root().join("src/taskd.rs")).unwrap();
    assert!(
        client.contains(".post(format!(\"http://{address}/rpc\"))")
            && client.contains("Endpoint")
            && client.contains(".no_proxy()")
            && client.contains("Policy::none()"),
        "the transport must use the daemon-owned authenticated endpoint"
    );
    assert!(
        !client.contains("UnixStream") && !client.contains("TcpListener"),
        "the MCP face cannot use Unix transport or listen itself"
    );

    // And the MCP face opens no listener of its own: stdio only. (The *tests*
    // stand up a loopback listener to play the daemon; the product must not.)
    let product: String = scanned_sources()
        .iter()
        .map(|(_, text)| without_test_modules(text))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        !product.contains("TcpListener"),
        "no listener may exist in this crate"
    );
    assert!(
        !product.contains("UnixListener"),
        "gmgn-mcpd must not listen on a unix socket either"
    );
    assert!(
        product.contains("transport::io::stdio()"),
        "the only transport is server-side stdio"
    );
    let tests: String = read_all(test_files())
        .iter()
        .map(|(_, text)| text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        tests.contains("TcpListener::bind"),
        "the integration test must exercise a real socket peer"
    );
}

#[test]
fn the_workspace_keeps_the_two_processes_separate() {
    // The MCP face and the authority are different binaries with different
    // dependency sets, and the daemon's exclusive lock is the reason.
    let root = crate_root();
    let workspace = root.parent().unwrap().parent().unwrap().join("Cargo.toml");
    let text = std::fs::read_to_string(&workspace).unwrap();
    assert!(text.contains("\"services/gmgn-taskd\""));
    assert!(text.contains("\"services/gmgn-mcpd\""));
    assert!(
        text.contains("[profile.release]"),
        "成员自己的 [profile] 会被工作区忽略，发布轮廓必须留在根清单里"
    );

    let taskd_manifest =
        std::fs::read_to_string(root.parent().unwrap().join("gmgn-taskd/Cargo.toml")).unwrap();
    assert!(taskd_manifest.contains("rusqlite"), "权威自己确实拥有存储");
}
