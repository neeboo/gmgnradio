//! The **second host** for the GPUI overlay's op contract, plus the gate that
//! decides whether a host is wired up.
//!
//! ## What problem this crate solves
//!
//! Today the only host that speaks the overlay's op contract is Swift:
//! `apps/macos/UnityHost/**` and `apps/macos/ProductHost/**`. Two machine gates
//! keep the UI and that host in step -- `apps/gpui-ui/tests/op_coverage.rs` (does
//! every op the UI emits have a handler somewhere) and
//! `apps/gpui-ui/tests/interface_parity.rs` (does every op's *declared field set*
//! actually get read by the declared handler). Both are written against the
//! Swift tree specifically.
//!
//! A Windows host is a *second* implementation of the same contract. The
//! interesting failure is not "the Swift host forgot an op" (already covered) --
//! it is **"a second host silently covers less than the first"**. So the gate
//! here is the same idea pointed at a different tree:
//!
//! [`check`] takes the contract (read from `interface_parity.rs`, the one copy),
//! a host's registration table, and that host's handler source, and returns
//! every place the host falls short:
//!
//! | gap | meaning |
//! |---|---|
//! | [`Gap::MissingRegistration`] | the UI can emit an op this host never declared |
//! | [`Gap::UnknownRegistration`] | this host declares an op the UI cannot emit |
//! | [`Gap::FieldNotDeclared`] | the UI sends a field this host promises nothing about |
//! | [`Gap::UnreadDeclaredField`] | this host claims to read a field the UI never sends |
//! | [`Gap::ImplementedWithoutHandler`] | this host *says* implemented, and no handler exists |
//!
//! **Any non-Swift host that passes this check is wired up.** That is the whole
//! acceptance criterion, and it is deliberately not "wrote the same `switch`".
//! Passing means: every op accounted for, every field accounted for, and every
//! claim of implementation backed by a file under the handler tree.
//!
//! ## The gate must be able to fail
//!
//! A gate nobody has seen fail is indistinguishable from a gate that cannot
//! fail. `tests/second_host_contract.rs` drives [`check`] with five deliberately
//! broken registries and asserts each specific [`Gap`] comes back, so the red
//! path is executed on every test run and not merely believed in. The
//! `gmgn-windows-host check` binary refuses (exit 1) when the real registry has
//! gaps, which is what makes it usable from a build script later.

pub mod contract;
pub mod credential;
pub mod handlers;
pub mod refusals;
pub mod registry;

#[cfg(windows)]
pub mod windows_acl;

use std::fmt;

use contract::OpContract;
use registry::{Registration, Status};

/// Where the handler tree lives, relative to this crate.
pub const HANDLER_TREE: &str = "src/handlers";

/// One way a host can fall short of the contract.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Gap {
    /// The UI emits `op`; the host declares nothing for it. The dangerous one:
    /// this is a click that does nothing.
    MissingRegistration { op: String, fields: Vec<String> },
    /// The host declares `op`; the contract has no such op. Usually a rename on
    /// the UI side that the host did not follow.
    UnknownRegistration { op: String },
    /// The UI sends `field` with `op`; the host's registration omits it.
    FieldNotDeclared { op: String, field: String },
    /// The host's registration lists `field` for `op`; the UI never sends it.
    /// A host reading a field nobody writes is reading `nil` forever.
    UnreadDeclaredField { op: String, field: String },
    /// The host says it implements `op` and the handler tree contains no
    /// occurrence of that op string. This is what stops "implemented" from being
    /// a checkbox.
    ImplementedWithoutHandler { op: String },
}

impl fmt::Display for Gap {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingRegistration { op, fields } => write!(
                f,
                "no registration for `{op}` (the UI emits it with {fields:?}) -- this click would do nothing"
            ),
            Self::UnknownRegistration { op } => {
                write!(f, "registered `{op}`, which is not in the contract")
            }
            Self::FieldNotDeclared { op, field } => {
                write!(f, "`{op}` sends `{field}`, which this host does not declare reading")
            }
            Self::UnreadDeclaredField { op, field } => {
                write!(f, "`{op}` declares reading `{field}`, which the UI never sends")
            }
            Self::ImplementedWithoutHandler { op } => write!(
                f,
                "`{op}` is marked implemented and no handler in `{HANDLER_TREE}/` mentions it"
            ),
        }
    }
}

/// What a passing check measured. Printed by the CLI so the migration has a
/// number that moves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub ops: usize,
    pub implemented: usize,
    pub unimplemented: usize,
}

impl fmt::Display for Report {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} contract ops: {} implemented, {} registered-but-unbuilt",
            self.ops, self.implemented, self.unimplemented
        )
    }
}

/// Check one host against the contract.
///
/// `handler_source` is the concatenation of every file under [`HANDLER_TREE`].
/// Passing it in (rather than reading it here) keeps this function pure and lets
/// the tests exercise the "claim without a handler" path without touching disk.
pub fn check(
    contract: &[OpContract],
    registry: &[Registration],
    handler_source: &str,
) -> Result<Report, Vec<Gap>> {
    let mut gaps = Vec::new();
    let mut implemented = 0usize;

    // Direction 1: every contract op must be registered, with at least its fields.
    for spec in contract {
        let Some(reg) = registry.iter().find(|r| r.op == spec.op) else {
            gaps.push(Gap::MissingRegistration {
                op: spec.op.clone(),
                fields: spec.fields.clone(),
            });
            continue;
        };
        for field in &spec.fields {
            if !reg.reads.contains(&field.as_str()) {
                gaps.push(Gap::FieldNotDeclared {
                    op: spec.op.clone(),
                    field: field.clone(),
                });
            }
        }
        if matches!(reg.status, Status::Implemented) {
            implemented += 1;
            if !handler_source.contains(&format!("\"{}\"", spec.op)) {
                gaps.push(Gap::ImplementedWithoutHandler { op: spec.op.clone() });
            }
        }
    }

    // Direction 2: nothing invented, and nothing claimed that is not sent.
    for reg in registry {
        match contract.iter().find(|c| c.op == reg.op) {
            None => gaps.push(Gap::UnknownRegistration { op: reg.op.to_owned() }),
            Some(spec) => {
                for field in reg.reads {
                    if !spec.fields.iter().any(|f| f == field) {
                        gaps.push(Gap::UnreadDeclaredField {
                            op: reg.op.to_owned(),
                            field: (*field).to_owned(),
                        });
                    }
                }
            }
        }
    }

    if gaps.is_empty() {
        Ok(Report {
            ops: contract.len(),
            implemented,
            unimplemented: contract.len() - implemented,
        })
    } else {
        Err(gaps)
    }
}

/// The repository root, from this crate's manifest directory.
pub fn repo_root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("apps/windows-host 的上一级是仓库根")
        .to_path_buf()
}

/// Read the contract source out of the real `interface_parity.rs`.
pub fn read_contract_source() -> Result<String, contract::ParseError> {
    let path = repo_root().join(contract::CONTRACT_SOURCE);
    let source = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    Ok(source)
}

/// Concatenate every `.rs` file under [`HANDLER_TREE`], which is what
/// "is there a handler for this op" is answered from.
pub fn read_handler_source() -> String {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(HANDLER_TREE);
    let mut out = String::new();
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().and_then(|e| e.to_str()) == Some("rs") {
                out.push_str(&std::fs::read_to_string(&path).unwrap_or_default());
                out.push('\n');
            }
        }
    }
    out
}
