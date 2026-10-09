//! The **one** copy of the op contract, read from where it already lives.
//!
//! `apps/gpui-ui/tests/interface_parity.rs` holds `const OPS: &[OpContract]`,
//! the machine-readable list of every op `apps/gpui-ui/src/**` can emit
//! together with the fields that go with it. That table is already kept honest
//! against the UI source by `interface_parity.rs` itself and against the op set
//! by `op_coverage.rs`.
//!
//! This crate does **not** keep a second copy. It re-reads that source at test
//! time and parses the table, for the same reason `contract.rs` in the daemon
//! re-derives its error-code list from the sources rather than restating it: a
//! second copy of one fact is a second place for it to be wrong, and the copy
//! that drifts is always the one nobody is looking at.
//!
//! Parsing Rust-with-a-known-shape is deliberate, not lazy. The alternatives
//! were worse:
//!
//! * moving `OPS` into a shared crate would make `apps/gpui-ui` depend on that
//!   crate and change a file this work does not own;
//! * hand-copying the 96 entries into this crate is exactly the duplication
//!   that would rot.
//!
//! A shape change in `interface_parity.rs` therefore shows up here as a loud
//! parse failure (and `tests/second_host_contract.rs` asserts the parse found a
//! plausible, unique, non-empty op set), never as a silently empty contract.

use std::fmt;

/// Where `interface_parity.rs` lives, relative to the repository root.
pub const CONTRACT_SOURCE: &str = "apps/gpui-ui/tests/interface_parity.rs";

/// The head of the table this module knows how to read.
const TABLE_HEAD: &str = "const OPS: &[OpContract] = &[";

/// One op the UI can emit, and the fields it emits with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpContract {
    /// e.g. `space.key.save`
    pub op: String,
    /// The field names the UI puts in the JSON command. Sorted, unique.
    pub fields: Vec<String>,
    /// `Some(target)` when the host is expected to rewrite this op into
    /// `target` (carrying the fields unchanged) before handling it. The
    /// rewrite *target* is what a host must therefore also accept.
    pub rewrite_to: Option<String>,
}

impl OpContract {
    /// The op a host must actually have a `case` for.
    ///
    /// For a rewriting op that is the target, because the fields are carried
    /// across unchanged and the target is where they are read.
    pub fn effective_op(&self) -> &str {
        self.rewrite_to.as_deref().unwrap_or(&self.op)
    }
}

/// Why the contract could not be read. Every variant is a failure the gate must
/// not paper over.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// The table head was not found at all.
    TableMissing,
    /// An entry's braces never balanced.
    UnterminatedEntry { at: usize },
    /// An entry had no `op:` literal.
    MissingOp { at: usize },
    /// An entry had no `ui_fields:` list.
    MissingFields { at: usize },
    /// Two entries declared the same op.
    DuplicateOp(String),
    /// The table parsed to nothing.
    Empty,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TableMissing => {
                write!(f, "{CONTRACT_SOURCE} no longer contains `{TABLE_HEAD}`")
            }
            Self::UnterminatedEntry { at } => {
                write!(f, "an `OpContract {{` entry at byte {at} never closed its brace")
            }
            Self::MissingOp { at } => {
                write!(f, "an `OpContract {{` entry at byte {at} has no `op:` literal")
            }
            Self::MissingFields { at } => {
                write!(f, "the entry at byte {at} has no `ui_fields:` list")
            }
            Self::DuplicateOp(op) => write!(f, "`{op}` is declared twice in the table"),
            Self::Empty => write!(f, "the table parsed to zero ops"),
        }
    }
}

impl std::error::Error for ParseError {}

/// Read the `OPS` table out of the real `interface_parity.rs` source.
///
/// `source` is passed in rather than read from disk so this is testable against
/// fixtures -- including deliberately broken ones.
pub fn parse_ops(source: &str) -> Result<Vec<OpContract>, ParseError> {
    let head = source.find(TABLE_HEAD).ok_or(ParseError::TableMissing)?;
    let mut from = head + TABLE_HEAD.len();
    let mut ops: Vec<OpContract> = Vec::new();

    while let Some(rel) = source[from..].find("OpContract {") {
        let at = from + rel;
        let brace = at + "OpContract ".len();
        debug_assert_eq!(&source[brace..brace + 1], "{");
        let end = balanced_brace_end(source, brace).ok_or(ParseError::UnterminatedEntry { at })?;
        let body = &source[brace + 1..end];
        ops.push(parse_entry(body, at)?);
        from = end + 1;
    }

    if ops.is_empty() {
        return Err(ParseError::Empty);
    }
    let mut seen = std::collections::BTreeSet::new();
    for op in &ops {
        if !seen.insert(op.op.as_str()) {
            return Err(ParseError::DuplicateOp(op.op.clone()));
        }
    }
    Ok(ops)
}

fn parse_entry(body: &str, at: usize) -> Result<OpContract, ParseError> {
    // Comments are stripped first, and this is not cosmetic. `interface_parity.rs`
    // documents the `stage.props.undo` entry with a prose comment that itself
    // quotes an op: `world.prop.command{op:"undo"}`. A comment-blind scan of the
    // *table region* finds `undo` as a 96th op that no host is expected to
    // handle. (That is how the 95-op count in `tests/second_host_contract.rs`
    // was established: by counting `OpContract {` entries, not by regex.)
    let body = strip_rust_comments(body);
    let body = body.as_str();

    let op = literal_after(body, "op:").ok_or(ParseError::MissingOp { at })?;

    let fields_at = body.find("ui_fields:").ok_or(ParseError::MissingFields { at })?;
    let open = body[fields_at..]
        .find('[')
        .map(|i| fields_at + i)
        .ok_or(ParseError::MissingFields { at })?;
    let close = body[open..]
        .find(']')
        .map(|i| open + i)
        .ok_or(ParseError::MissingFields { at })?;
    let mut fields: Vec<String> = string_literals(&body[open + 1..close]);
    fields.sort();
    fields.dedup();

    // `rewrite_to: Some("x")` / `rewrite_to: None`.
    //
    // This must not be "the next string literal after `rewrite_to:`": when the
    // value is `None` the next literal in the entry is the first handler's *file
    // path*, and the contract would appear to rewrite `agent.login` into
    // `apps/macos/ProductHost/ProductHost.swift`. Caught by reading the CLI's own
    // output; `rewrites_are_parsed_as_rewrites_not_as_handler_paths` in
    // `tests/second_host_contract.rs` keeps it caught.
    let rewrite_to = body.find("rewrite_to:").and_then(|i| parse_rewrite(&body[i + "rewrite_to:".len()..]));

    Ok(OpContract { op, fields, rewrite_to })
}

/// Parse the value of a `rewrite_to:` field: `None`, or `Some("target")`.
fn parse_rewrite(rest: &str) -> Option<String> {
    let rest = rest.trim_start();
    if rest.starts_with("None") {
        return None;
    }
    let open = rest.find('(')?;
    let close = rest[open..].find(')')? + open;
    string_literals(&rest[open + 1..close]).into_iter().next()
}

/// Remove `//` and `/* */` comments without touching string literals.
///
/// Character-based, not byte-based: `interface_parity.rs` carries Chinese prose
/// in its comments and doc strings, and a byte-wise walk that pushed
/// `bytes[i] as char` would turn every continuation byte into a separate Latin-1
/// character. ASCII patterns would still be found, so the bug would be silent --
/// which is the reason to do it properly rather than to rely on that.
///
/// Public because the credential ban in `tests/credential_store.rs` scans source
/// the same way. That scan has to be comment-blind or it is self-defeating: the
/// one place a maintainer must be free to *name* `SecItemAdd` is the comment
/// explaining why it is not called. A ban that cannot be described is a ban that
/// gets deleted. String literals are deliberately **kept**, because that is
/// exactly how the banned things would appear in real code -- `Cmd::new("security")`
/// with `"find-generic-password"` as an argument is a string literal.
pub fn strip_rust_comments(source: &str) -> String {
    let mut out = String::with_capacity(source.len());
    let mut chars = source.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                out.push('"');
                while let Some(c) = chars.next() {
                    out.push(c);
                    match c {
                        '\\' => {
                            if let Some(escaped) = chars.next() {
                                out.push(escaped);
                            }
                        }
                        '"' => break,
                        _ => {}
                    }
                }
            }
            '/' if chars.peek() == Some(&'/') => {
                for c in chars.by_ref() {
                    if c == '\n' {
                        out.push('\n');
                        break;
                    }
                }
            }
            '/' if chars.peek() == Some(&'*') => {
                chars.next();
                let mut prev = '\0';
                for c in chars.by_ref() {
                    if prev == '*' && c == '/' {
                        break;
                    }
                    prev = c;
                }
                out.push('\n');
            }
            _ => out.push(c),
        }
    }
    out
}

/// The first `"..."` literal after `key`.
fn literal_after(haystack: &str, key: &str) -> Option<String> {
    let at = haystack.find(key)? + key.len();
    let rest = &haystack[at..];
    let open = rest.find('"')?;
    let mut out = String::new();
    let mut chars = rest[open + 1..].chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => out.push(chars.next()?),
            _ => out.push(c),
        }
    }
    None
}

/// Every `"..."` literal in a fragment.
fn string_literals(fragment: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = fragment.char_indices();
    while let Some((i, c)) = chars.next() {
        if c != '"' {
            continue;
        }
        let mut value = String::new();
        let mut closed = false;
        while let Some((_, c)) = chars.next() {
            match c {
                '"' => {
                    closed = true;
                    break;
                }
                '\\' => {
                    if let Some((_, escaped)) = chars.next() {
                        value.push(escaped);
                    }
                }
                _ => value.push(c),
            }
        }
        if closed {
            out.push(value);
        }
        let _ = i;
    }
    out
}

/// Index of the `}` matching the `{` at `open`, skipping string literals, line
/// comments and block comments. Same discipline as
/// `services/gmgn-taskd/src/contract.rs::without_test_modules` and
/// `apps/gpui-ui/tests/interface_parity.rs::balanced_brace_end`.
fn balanced_brace_end(source: &str, open: usize) -> Option<usize> {
    let bytes = source.as_bytes();
    let mut depth = 0usize;
    let mut i = open;
    while i < bytes.len() {
        match bytes[i] {
            b'"' => {
                i += 1;
                while i < bytes.len() {
                    if bytes[i] == b'\\' {
                        i += 2;
                        continue;
                    }
                    if bytes[i] == b'"' {
                        break;
                    }
                    i += 1;
                }
            }
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
                continue;
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                    i += 1;
                }
                i += 1;
            }
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}
