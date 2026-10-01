mod artifact;
mod cli;
mod contract;
mod daemon;
mod files;
mod memory;
mod messages;
mod model;
mod provider;
mod resident;
mod store;
mod world;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|s| s == "--help" || s == "-h") {
        println!("gmgn-taskd --root <absolute-directory> --socket <absolute-socket> --concurrency 2 [--legacy-root <absolute-directory>]");
        println!("gmgn-taskd world-import --root <absolute-directory> --bundle <worlds.json> [--producer <name>] [--out <file>]");
        println!("gmgn-taskd world-dump --root <absolute-directory> [--out <file>]");
        return;
    }
    // Offline authority tooling: same root, same database, but it takes the
    // daemon's exclusive lock, so it cannot become a second writer.
    let offline: Option<fn(&[String]) -> Result<i32, String>> = match args.get(1).map(String::as_str) {
        Some("world-import") => Some(cli::world_import),
        Some("world-dump") => Some(cli::world_dump),
        _ => None,
    };
    if let Some(command) = offline {
        match command(&args[2..]) {
            Ok(code) => std::process::exit(code),
            Err(message) => {
                eprintln!("gmgn-taskd: {message}");
                std::process::exit(1);
            }
        }
    }
    // Applied before any thread exists; all private SQLite journals inherit 0600.
    unsafe {
        libc::umask(0o077);
    }
    if let Err(code) = start() {
        eprintln!("gmgn-taskd: {code}");
        std::process::exit(1);
    }
}

fn start() -> model::Result<()> {
    // Register the statically linked sqlite-vec extension before any SQLite
    // connection is opened anywhere in this process (auto_extension applies to
    // connections opened after the registration; store.rs re-asserts it before
    // its own open as well).
    memory::register_vec();
    let options = daemon::options()?;
    files::directory(&options.root)?;
    let root = options
        .root
        .canonicalize()
        .map_err(|_| "storage_unavailable")?;
    if options
        .socket
        .parent()
        .and_then(|p| p.canonicalize().ok())
        .as_ref()
        != Some(&root)
    {
        return Err("socket_outside_private_root");
    }
    let lock = files::open_private(&root.join("taskd.lock"))?;
    fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "already_running")?;
    if let Ok(metadata) = std::fs::symlink_metadata(&options.socket) {
        if !metadata.file_type().is_socket() {
            return Err("unsafe_socket_path");
        }
        std::fs::remove_file(&options.socket).map_err(|_| "socket_unavailable")?;
    }
    let db = store::Database::open(root, options.legacy)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|_| "runtime_unavailable")?;
    runtime.block_on(async {
        let listener =
            tokio::net::UnixListener::bind(&options.socket).map_err(|_| "socket_unavailable")?;
        std::fs::set_permissions(&options.socket, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "socket_unavailable")?;
        daemon::run(listener, db, options.concurrency).await
    })
}
