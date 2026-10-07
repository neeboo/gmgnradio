//! `gmgn-mcpd` — the MCP face of the gmgn living world.
//!
//! One process, two sides:
//!
//! * **stdio** towards the MCP client (the agent host). The client spawns it on
//!   demand and may kill it at any time.
//! * **authenticated loopback HTTP** towards `gmgn-taskd`, with one JSON
//!   request and reply per POST /rpc.
//!
//! It is deliberately **not** part of `gmgn-taskd`. The daemon holds an exclusive
//! lock on its private root (`services/gmgn-taskd/src/main.rs`), so a second
//! face inside it would make an MCP client restart reach into the authority. This
//! process holds no database handle, no lock and no credential.
//!
//! It also opens **no port**: stdio only, exactly as the design plan pins
//! (`docs/plans/2026-10-02-rust-world-authority-and-mcp.md` §6.1).

mod catalog;
mod grant;
mod server;
mod taskd;

use grant::GrantSource;
use server::GmgnMcpServer;
use std::path::PathBuf;
use std::process::ExitCode;
use taskd::Client;

const USAGE: &str = "\
gmgn-mcpd — MCP (stdio) face over the gmgn-taskd authority

USAGE:
    gmgn-mcpd --endpoint-file <absolute-taskd-endpoint.json> [--grant <absolute-grant.json>]
              [--server-name <name>] [--help]
    gmgn-mcpd --list-tools

OPTIONS:
    --endpoint-file <path> Private gmgn-taskd connection descriptor. Required.
                          other way to reach the world, by design.
    --grant <path>        Armed-round grant document written by the host. When it
                          is absent the read-only tools still work and every
                          action tool refuses with `mcp_grant_not_configured`.
    --server-name <name>  MCP server namespace, default `gmgn`. Clients see the
                          tools as `mcp__<name>__<tool>`.
    --list-tools          Print this build's tool catalog as JSON and exit. No
                          endpoint, no session: it answers where the tool
                          definitions live, from the single place they exist.
    -h, --help            Print this text.
";

fn main() -> ExitCode {
    let mut endpoint_file: Option<PathBuf> = None;
    let mut grant: Option<PathBuf> = None;
    let mut server_name = "gmgn".to_owned();

    let mut args = std::env::args().skip(1);
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "-h" | "--help" => {
                print!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            "--list-tools" => {
                let catalog: Vec<serde_json::Value> = catalog::TOOLS
                    .iter()
                    .map(|tool| {
                        serde_json::json!({
                            "name": tool.name,
                            "kind": match tool.kind {
                                catalog::Kind::ReadOnly => "read_only",
                                catalog::Kind::Action => "action",
                            },
                            "backend": tool.backend,
                            "description": tool.description,
                            "inputSchema": (tool.input_schema)(),
                        })
                    })
                    .collect();
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "count": catalog::names().len(),
                        "tools": catalog,
                    }))
                    .expect("the catalog is JSON by construction")
                );
                return ExitCode::SUCCESS;
            }
            "--endpoint-file" => match args.next() {
                Some(value) => endpoint_file = Some(PathBuf::from(value)),
                None => return usage_error("--endpoint-file 需要一个路径"),
            },
            "--grant" => match args.next() {
                Some(value) => grant = Some(PathBuf::from(value)),
                None => return usage_error("--grant 需要一个路径"),
            },
            "--server-name" => match args.next() {
                Some(value) if !value.is_empty() => server_name = value,
                _ => return usage_error("--server-name 需要一个非空名字"),
            },
            other => return usage_error(&format!("未知参数 {other}")),
        }
    }

    let Some(endpoint_file) = endpoint_file else {
        return usage_error("必须给 --endpoint-file：本进程没有第二条通往世界的路");
    };
    if !endpoint_file.is_absolute() {
        return usage_error("--endpoint-file 必须是绝对路径");
    }

    let client = Client::new(endpoint_file);
    // The authority endpoint file is resolved once, at startup, and never from the
    // grant: a grant may only *narrow* what this process does, never widen it.
    let grant_source = match grant {
        Some(path) => GrantSource::at(path),
        None => GrantSource::none(),
    };
    let handler = GmgnMcpServer::new(client, grant_source, server_name, "stdio".to_owned());

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("gmgn-mcpd: 无法启动运行时：{error}");
            return ExitCode::FAILURE;
        }
    };

    runtime.block_on(async move {
        match rmcp::serve_server(handler, rmcp::transport::io::stdio()).await {
            Ok(running) => match running.waiting().await {
                Ok(_) => ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("gmgn-mcpd: 会话结束异常：{error}");
                    ExitCode::FAILURE
                }
            },
            Err(error) => {
                eprintln!("gmgn-mcpd: 无法在 stdio 上建立 MCP 会话：{error}");
                ExitCode::FAILURE
            }
        }
    })
}

fn usage_error(message: &str) -> ExitCode {
    eprintln!("gmgn-mcpd: {message}\n\n{USAGE}");
    ExitCode::from(2)
}
