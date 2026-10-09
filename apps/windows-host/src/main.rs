//! `gmgn-windows-host` -- the host's own two faces.
//!
//! ```text
//! gmgn-windows-host contract   # the spec: every op, its fields, its status
//! gmgn-windows-host check      # the gate: exit 1 if this host falls short
//! ```
//!
//! `check` is the entry point a build script (or a Windows CI job) would call.
//! It is deliberately a separate exit code rather than a panic, so it composes.

use std::process::ExitCode;

use gmgn_windows_host::registry::{self, Status};
use gmgn_windows_host::{check, contract, read_contract_source, read_handler_source};

fn main() -> ExitCode {
    let mode = std::env::args().nth(1).unwrap_or_else(|| "check".to_owned());
    match mode.as_str() {
        "contract" => {
            print_contract();
            ExitCode::SUCCESS
        }
        "check" => run_check(),
        other => {
            eprintln!("unknown mode `{other}`; expected `contract` or `check`");
            ExitCode::from(2)
        }
    }
}

fn load() -> Result<Vec<contract::OpContract>, contract::ParseError> {
    contract::parse_ops(&read_contract_source()?)
}

fn print_contract() {
    let ops = match load() {
        Ok(ops) => ops,
        Err(e) => {
            eprintln!("contract: {e}");
            std::process::exit(2);
        }
    };

    println!("# The GPUI overlay op contract, as this host reads it");
    println!("# source: {}", contract::CONTRACT_SOURCE);
    println!("# ops: {}", ops.len());
    println!();
    println!("{:<28} {:<6} {:<44} {}", "op", "status", "fields", "rewrite");
    for spec in &ops {
        let status = match registry::get(&spec.op).map(|r| r.status) {
            Some(Status::Implemented) => "built",
            Some(Status::Unimplemented { .. }) => "not-built",
            None => "MISSING",
        };
        println!(
            "{:<28} {:<6} {:<44} {}",
            spec.op,
            status,
            spec.fields.join(","),
            spec.rewrite_to.as_deref().unwrap_or("-")
        );
    }
    println!();
    println!(
        "{}",
        gmgn_windows_host::Report {
            ops: ops.len(),
            implemented: registry::implemented_count(),
            unimplemented: ops.len() - registry::implemented_count(),
        }
    );
}

fn run_check() -> ExitCode {
    let ops = match load() {
        Ok(ops) => ops,
        Err(e) => {
            eprintln!("FAIL contract could not be read: {e}");
            return ExitCode::FAILURE;
        }
    };
    let handlers = read_handler_source();
    match check(&ops, registry::REGISTRY, &handlers) {
        Ok(report) => {
            println!("OK   {report}");
            ExitCode::SUCCESS
        }
        Err(gaps) => {
            eprintln!("FAIL {} gap(s) between the contract and this host:", gaps.len());
            for gap in &gaps {
                eprintln!("  - {gap}");
            }
            ExitCode::FAILURE
        }
    }
}
