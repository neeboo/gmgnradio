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
                 「杀掉 MCP 不影响权威」就不再成立。所有访问都必须走 taskd 的 socket。",
                path.display()
            );
        }
    }
}

#[test]
fn the_manifest_does_not_depend_on_the_storage_stack() {
    let manifest = std::fs::read_to_string(crate_root().join("Cargo.toml")).unwrap();
    for forbidden in ["rusqlite", "sqlite-vec", "fs2", "libc"] {
        assert!(
            !manifest.contains(forbidden),
            "gmgn-mcpd 的依赖里出现了 `{forbidden}`：它不该有能力直接碰权威存储"
        );
    }
    // It needs one loopback transport; no HTTP server/client stack belongs here.
    assert!(manifest.contains("rmcp"));
    for forbidden in ["reqwest", "hyper", "axum", "tiny_http", "warp"] {
        assert!(
            !manifest.contains(forbidden),
            "gmgn-mcpd 引入了 HTTP 栈 `{forbidden}`：仅允许 taskd 的 loopback 通道"
        );
    }
}

#[test]
fn the_only_way_into_the_world_is_the_daemon_socket() {
    // Every world access in this crate goes through `taskd::Client`, and that
    // client has exactly one constructor and one call path.
    let client = std::fs::read_to_string(crate_root().join("src/taskd.rs")).unwrap();
    assert!(
        client.contains("TcpStream::connect") && client.contains("Endpoint"),
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
        .map(|(_, text)| text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert!(!product.contains("TcpListener"), "no listener may exist in this crate");
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
    let workspace = root
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("Cargo.toml");
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
