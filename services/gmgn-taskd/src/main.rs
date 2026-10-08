mod artifact;
mod agent_scheduler;
mod agent_tools;
mod agent_runtime_tools;
mod agent_runtime;
mod agent_cli;
mod agent_claude;
mod agent_chat;
mod agent_dsh;
mod screen_playback;
mod screen_state;
mod speech_delivery;
mod chat_speech;
mod activity;
mod canonical_json;
mod cli;
mod contract;
mod daemon;
mod files;
mod http;
mod memory;
mod media;
mod messages;
mod model;
mod music;
mod music_playback;
mod placement;
mod provider;
mod resident;
mod store;
mod support_grid;
mod voice;
mod world;
mod wish_control;
mod world_activity;
mod world_prop;
mod world_prop_capability;
mod world_activity_approach;
mod world_prop_grip;
mod world_prop_measurement;
mod world_device;
mod resident_intent;
mod music_library;
mod music_program;
mod music_program_rules;
mod product_settings;
mod chat_attachments;
mod presence_selection;
mod wish_reference;
mod music_knowledge;
mod world_control;
mod inbox_control;
mod marble_control;
mod marble_geometry;
mod stage_video;
mod music_cache;
mod jukebox;
mod music_account;
mod music_account_http;
mod generation_configuration;

#[cfg(test)]
mod rpc_wiring_tests;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|s| s == "--help" || s == "-h") {
        println!("gmgn-taskd --root <absolute-directory> --endpoint-file <absolute-file> --concurrency 2 [--legacy-root <absolute-directory>]");
        println!("The endpoint file stores the authenticated HTTP endpoint descriptor.");
        println!("Public video caching: --media-helper <absolute-yt-dlp> --media-helper-sha256 <pinned-hex> --media-deno <absolute-deno> --media-deno-sha256 <pinned-hex>. No PATH discovery.");
        println!("gmgn-taskd world-import --root <absolute-directory> --bundle <worlds.json> [--producer <name>] [--out <file>]");
        println!("gmgn-taskd world-dump --root <absolute-directory> [--out <file>]");
        return;
    }
    // Offline authority tooling: same root, same database, but it takes the
    // daemon's exclusive lock, so it cannot become a second writer.
    let offline: Option<fn(&[String]) -> Result<i32, String>> =
        match args.get(1).map(String::as_str) {
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
    #[cfg(unix)]
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
        .endpoint_file
        .parent()
        .and_then(|p| p.canonicalize().ok())
        .as_ref()
        != Some(&root)
    {
        return Err("endpoint_outside_private_root");
    }
    let lock = files::open_private(&root.join("taskd.lock"))?;
    fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "already_running")?;
    if let Ok(metadata) = std::fs::symlink_metadata(&options.endpoint_file) {
        if !metadata.file_type().is_file() {
            return Err("unsafe_endpoint_path");
        }
        // Never overwrite an arbitrary user file at the endpoint location.
        let previous = files::read(&options.endpoint_file, 4096)?;
        let endpoint: gmgn_protocol::Endpoint =
            serde_json::from_slice(&previous).map_err(|_| "unsafe_endpoint_path")?;
        endpoint.validate_previous_descriptor().map_err(|_| "unsafe_endpoint_path")?;
    }
    let db = store::Database::open(root, options.legacy)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|_| "runtime_unavailable")?;
    runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .map_err(|_| "endpoint_unavailable")?;
        let endpoint = gmgn_protocol::Endpoint {
            version: 2,
            address: listener
                .local_addr()
                .map_err(|_| "endpoint_unavailable")?
                .to_string(),
            token: uuid::Uuid::new_v4().to_string(),
        };
        let bytes = serde_json::to_vec(&endpoint).map_err(|_| "endpoint_unavailable")?;
        files::publish(&options.endpoint_file, &bytes)?;
        http::run_with_media(listener, db, options.concurrency, endpoint.token, options.media).await
    })
}
