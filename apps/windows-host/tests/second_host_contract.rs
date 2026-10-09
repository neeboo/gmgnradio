//! The **second-host consistency gate**.
//!
//! This is the entry criterion from the Windows-host work: *any* non-Swift host
//! that passes [`check`] against the real contract is wired up, and the gate is
//! the same one the `gmgn-windows-host check` binary exposes.
//!
//! Two things are being tested here at once, and they are different:
//!
//! 1. **The host is complete.** `the_windows_host_satisfies_the_contract` runs
//!    the real registry against the real contract.
//! 2. **The gate works.** Five tests drive deliberately broken registries and
//!    assert the exact [`Gap`] each one must produce. Without these, the first
//!    test would only prove that an unknown function returns `Ok` -- a gate that
//!    has never been seen to fail cannot be distinguished from one that cannot
//!    fail, and this repository has been bitten by exactly that before
//!    (`tools/test-resident-tv-look.swift` documents its own injection switches
//!    for the same reason).
//!
//! The contract itself is read from `apps/gpui-ui/tests/interface_parity.rs` --
//! the one copy -- not restated here. `the_contract_parses_to_its_own_entry_count`
//! is the parse's own guard: it compares the number of `OpContract {` entries in
//! the table against what [`gmgn_windows_host::contract::parse_ops`] recovered,
//! which is precisely the check that caught a 96th "op" that was only ever
//! mentioned in a comment.

use std::collections::BTreeSet;

use gmgn_windows_host::contract::{self, OpContract};
use gmgn_windows_host::registry::{self, Registration, Status};
use gmgn_windows_host::{Gap, check, read_contract_source, read_handler_source};

fn source() -> String {
    read_contract_source().expect("interface_parity.rs must be readable from this crate")
}

fn ops() -> Vec<OpContract> {
    contract::parse_ops(&source()).expect("the OPS table must parse")
}

fn registry() -> Vec<Registration> {
    registry::REGISTRY.to_vec()
}

/// The registry minus one op -- the "this host forgot a click" case.
fn registry_without(op: &str) -> Vec<Registration> {
    registry().into_iter().filter(|r| r.op != op).collect()
}

/// The registry with one op's declared field set replaced.
fn registry_with_reads(op: &str, reads: &'static [&'static str]) -> Vec<Registration> {
    registry()
        .into_iter()
        .map(|mut r| {
            if r.op == op {
                r.reads = reads;
            }
            r
        })
        .collect()
}

/// The registry with one op's status forced to `Implemented`.
fn registry_claiming(op: &str) -> Vec<Registration> {
    registry()
        .into_iter()
        .map(|mut r| {
            if r.op == op {
                r.status = Status::Implemented;
            }
            r
        })
        .collect()
}

// ---------------------------------------------------------------- the contract

#[test]
fn the_contract_parses_to_its_own_entry_count() {
    let source = source();
    let head = source
        .find("const OPS: &[OpContract] = &[")
        .expect("the table head must exist");
    let tail = source
        .find("const UI_RETIRED_OPS")
        .expect("the table must be followed by the retired-op table");
    let entries = source[head..tail].matches("OpContract {").count();

    let parsed = ops().len();
    assert_eq!(
        parsed, entries,
        "the parser recovered {parsed} ops but the table has {entries} `OpContract {{` entries. \
         A mismatch means the parser is reading something that is not an entry (a comment, a doc \
         line) or skipping a real one."
    );
}

#[test]
fn the_contract_has_unique_non_empty_ops() {
    let ops = ops();
    let mut seen = BTreeSet::new();
    for op in &ops {
        assert!(!op.op.is_empty(), "an entry has an empty op name");
        assert!(
            op.op.contains('.'),
            "`{}` does not look like a namespaced op",
            op.op
        );
        assert!(seen.insert(op.op.clone()), "`{}` is declared twice", op.op);
    }
    assert!(
        ops.len() > 50,
        "only {} ops parsed; the contract is far larger than that",
        ops.len()
    );
}

#[test]
fn rewrites_are_parsed_as_rewrites_not_as_handler_paths() {
    let ops = ops();
    let rewriting: Vec<&OpContract> = ops.iter().filter(|o| o.rewrite_to.is_some()).collect();

    // Every rewrite target must itself be an op in the contract: a host that
    // rewrites into a name nobody handles has moved the gap, not closed it.
    let names: BTreeSet<&str> = ops.iter().map(|o| o.op.as_str()).collect();
    for op in &rewriting {
        let target = op.rewrite_to.as_deref().unwrap();
        assert!(
            names.contains(target),
            "`{}` rewrites to `{target}`, which is not an op in the contract",
            op.op
        );
        assert_ne!(
            target,
            op.op,
            "`{}` rewrites to itself, which would not terminate",
            op.op
        );
    }

    // The regression this test exists for: `rewrite_to: None` must not swallow
    // the next literal in the entry, which is a handler's *file path*.
    for op in &ops {
        if let Some(target) = &op.rewrite_to {
            assert!(
                !target.contains('/') && !target.ends_with(".swift"),
                "`{}` rewrites to `{target}`, which looks like a file path -- the parser is \
                 reading past `None`",
                op.op
            );
        }
    }
}

// ------------------------------------------------------------------ green path

#[test]
fn the_windows_host_satisfies_the_contract() {
    let ops = ops();
    let handlers = read_handler_source();
    assert!(
        !handlers.trim().is_empty(),
        "`src/handlers/` produced no source; the implemented-op check would be vacuous"
    );
    match check(&ops, &registry(), &handlers) {
        Ok(report) => {
            println!("gate: {report}");
            assert_eq!(report.ops, ops.len());
            assert_eq!(report.implemented, registry::implemented_count());
            assert!(
                report.implemented >= 1,
                "the host claims nothing is implemented; the skeleton has no live handler at all"
            );
        }
        Err(gaps) => {
            let rendered: Vec<String> = gaps.iter().map(ToString::to_string).collect();
            panic!(
                "the windows host does not satisfy the contract:\n  - {}",
                rendered.join("\n  - ")
            );
        }
    }
}

#[test]
fn the_registry_and_the_handler_tree_agree_on_implemented_ops() {
    let mut from_registry = registry::implemented_ops();
    let mut from_handlers = registry::declared_implemented().to_vec();
    from_registry.sort_unstable();
    from_handlers.sort_unstable();
    assert_eq!(
        from_registry, from_handlers,
        "`registry::REGISTRY` and `handlers::IMPLEMENTED_OPS` disagree about what this host can do"
    );
}

#[test]
fn every_implemented_op_is_reachable_through_dispatch() {
    use gmgn_windows_host::credential::SecretStore;
    use gmgn_windows_host::handlers::{FieldMap, FieldValue, HostState, Outcome, dispatch};

    let root = std::env::temp_dir().join(format!("gmgn-host-dispatch-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let store = SecretStore::with_root(&root);
    let mut state = HostState::default();

    // `space.key.save` really writes.
    let mut fields = FieldMap::new();
    fields.insert("apiKey".to_owned(), FieldValue::Text("  sk-live-abc  ".to_owned()));
    let outcome = dispatch("space.key.save", &fields, &store, &mut state)
        .expect("space.key.save must be implemented");
    assert_eq!(outcome, Outcome::KeyConfigured(true));
    assert_eq!(
        store.read("world-labs-api-key").as_deref(),
        Some("sk-live-abc"),
        "the handler must trim, like MarbleAPIKeyProvider.save does"
    );

    // `space.key.clear` really clears.
    let outcome = dispatch("space.key.clear", &FieldMap::new(), &store, &mut state)
        .expect("space.key.clear must be implemented");
    assert_eq!(outcome, Outcome::KeyConfigured(false));
    assert_eq!(store.read("world-labs-api-key"), None);

    // `app.language` accepts the three locales and refuses anything else.
    let mut fields = FieldMap::new();
    fields.insert("locale".to_owned(), FieldValue::Text("ja".to_owned()));
    assert_eq!(
        dispatch("app.language", &fields, &store, &mut state).unwrap(),
        Outcome::Language("ja".to_owned())
    );
    fields.insert("locale".to_owned(), FieldValue::Text("fr".to_owned()));
    assert!(dispatch("app.language", &fields, &store, &mut state).is_err());

    // An op that is registered but not built must say so, not silently succeed.
    let err = dispatch("agent.login", &FieldMap::new(), &store, &mut state)
        .expect_err("agent.login is not implemented in this host");
    let rendered = err.to_string();
    assert!(
        rendered.contains("not implemented"),
        "expected a not-implemented refusal, got `{rendered}`"
    );

    let _ = std::fs::remove_dir_all(&root);
}

// -------------------------------------------------------------------- red path

#[test]
fn the_gate_goes_red_when_a_registration_is_missing() {
    let ops = ops();
    let handlers = read_handler_source();
    // `space.key.save` carries a credential; losing it silently is the exact
    // failure this gate exists to prevent.
    let broken = registry_without("space.key.save");

    let gaps = check(&ops, &broken, &handlers).expect_err("a missing registration must fail");
    let rendered: Vec<String> = gaps.iter().map(ToString::to_string).collect();
    println!("injected: dropped `space.key.save`\n  - {}", rendered.join("\n  - "));
    assert!(
        gaps.iter().any(|g| matches!(
            g,
            Gap::MissingRegistration { op, .. } if op == "space.key.save"
        )),
        "expected MissingRegistration for `space.key.save`, got {gaps:?}"
    );
}

#[test]
fn the_gate_goes_red_when_a_registration_is_invented() {
    let ops = ops();
    let handlers = read_handler_source();
    let mut broken = registry();
    broken.push(Registration {
        op: "not.a.real.op",
        reads: &[],
        status: Status::Unimplemented { reason: "injected" },
    });

    let gaps = check(&ops, &broken, &handlers).expect_err("an invented op must fail");
    println!("injected: registered `not.a.real.op`\n  - {}", gaps
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\n  - "));
    assert!(
        gaps.iter().any(|g| matches!(
            g,
            Gap::UnknownRegistration { op } if op == "not.a.real.op"
        )),
        "expected UnknownRegistration, got {gaps:?}"
    );
}

#[test]
fn the_gate_goes_red_when_a_declared_field_is_dropped() {
    let ops = ops();
    let handlers = read_handler_source();
    // `agent.save` carries hostPrompt, planningModel and residentPersona.
    let broken = registry_with_reads("agent.save", &["hostPrompt"]);

    let gaps = check(&ops, &broken, &handlers).expect_err("a dropped field must fail");
    println!("injected: `agent.save` declares only `hostPrompt`\n  - {}", gaps
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\n  - "));
    let dropped: BTreeSet<&str> = gaps
        .iter()
        .filter_map(|g| match g {
            Gap::FieldNotDeclared { op, field } if op == "agent.save" => Some(field.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(
        dropped,
        BTreeSet::from(["planningModel", "residentPersona"]),
        "expected exactly the two dropped fields, got {gaps:?}"
    );
}

#[test]
fn the_gate_goes_red_when_a_registration_reads_a_field_the_ui_never_sends() {
    let ops = ops();
    let handlers = read_handler_source();
    // `agent.login` carries no fields at all.
    let broken = registry_with_reads("agent.login", &["inventedField"]);

    let gaps = check(&ops, &broken, &handlers).expect_err("a phantom field must fail");
    println!("injected: `agent.login` declares reading `inventedField`\n  - {}", gaps
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\n  - "));
    assert!(
        gaps.iter().any(|g| matches!(
            g,
            Gap::UnreadDeclaredField { op, field } if op == "agent.login" && field == "inventedField"
        )),
        "expected UnreadDeclaredField, got {gaps:?}"
    );
}

#[test]
fn the_gate_goes_red_when_implemented_has_no_handler() {
    let ops = ops();
    let handlers = read_handler_source();
    // `agent.login` has no handler in this host today. Claiming it is the exact
    // "checkbox instead of code" failure.
    assert!(
        !handlers.contains("\"agent.login\""),
        "this test needs `agent.login` to be genuinely unimplemented; the handler tree now has one"
    );
    let broken = registry_claiming("agent.login");

    let gaps = check(&ops, &broken, &handlers).expect_err("a claim without a handler must fail");
    println!("injected: `agent.login` marked implemented with no handler\n  - {}", gaps
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\n  - "));
    assert!(
        gaps.iter().any(|g| matches!(
            g,
            Gap::ImplementedWithoutHandler { op } if op == "agent.login"
        )),
        "expected ImplementedWithoutHandler, got {gaps:?}"
    );
}
