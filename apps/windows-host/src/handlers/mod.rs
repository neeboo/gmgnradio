//! The handlers this host actually implements, and the field types they accept.
//!
//! The macOS host's signature is `func command(_ value: [String: Any]) -> Bool`
//! (`UnityProductSettings.swift:105`, `ProductSettingsParity.swift`): an
//! already-decoded field map in, accepted-or-refused out. This module keeps that
//! shape, minus the `Any`, because the Windows host decodes JSON in its platform
//! layer and a typed field map is what makes the contract checkable.
//!
//! Deliberately **not** JSON: this crate has no dependencies, so the platform
//! layer owns decoding. That is also where it belongs -- decoding is a
//! boundary concern, and a handler that receives a `FieldMap` cannot be
//! distracted by JSON syntax errors.
//!
//! ## Why the handlers live in their own tree
//!
//! `tests/second_host_contract.rs` refuses to take a registration's word for it
//! that an op is implemented: for every [`Status::Implemented`] entry the op
//! literal must be found in a file under this directory. Flipping a status to
//! `Implemented` without writing a handler turns the gate red, which is the
//! whole point of having a gate rather than a checklist.

use std::collections::BTreeMap;
use std::fmt;

use crate::credential::{SecretStore, StoreError};

/// The `world-labs-api-key` name, matching `MarbleAPIKeyProvider.defaultFileURL`
/// on the macOS side. Held once so the handler and the snapshot agree.
pub const MARBLE_KEY_NAME: &str = "world-labs-api-key";

/// The locales `app.language` accepts. Taken verbatim from
/// `UnityProductSettings.swift`: `["zh-CN", "en", "ja"].contains(locale)`.
pub const ALLOWED_LOCALES: &[&str] = &["zh-CN", "en", "ja"];

/// One field of a decoded command.
#[derive(Debug, Clone, PartialEq)]
pub enum FieldValue {
    Text(String),
    Flag(bool),
    Int(i64),
}

impl FieldValue {
    pub fn as_text(&self) -> Option<&str> {
        match self {
            Self::Text(v) => Some(v),
            _ => None,
        }
    }
}

/// A decoded command: the op plus its fields.
pub type FieldMap = BTreeMap<String, FieldValue>;

/// A refusal. The macOS host refuses by returning `false` and says nothing more;
/// a named reason is strictly better and costs nothing, so the skeleton names
/// one. The strings are **not** new wire error codes -- the published codes live
/// in `services/gmgn-taskd/src/contract.rs` and this layer puts nothing on the
/// wire that the daemon has not published.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommandError {
    /// A required field was absent or had the wrong type.
    MissingField(&'static str),
    /// A field was present but outside its allowed set.
    InvalidField(&'static str),
    /// The credential store refused.
    Store(StoreError),
    /// The op is registered but not implemented yet -- carries the registration's
    /// own reason so a caller sees the same explanation the gate prints.
    NotImplemented(&'static str),
    /// No such op in the contract at all.
    UnknownOp,
}

impl fmt::Display for CommandError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingField(name) => write!(f, "missing or mistyped field `{name}`"),
            Self::InvalidField(name) => write!(f, "field `{name}` is outside its allowed set"),
            Self::Store(e) => write!(f, "credential store: {e}"),
            Self::NotImplemented(reason) => write!(f, "not implemented: {reason}"),
            Self::UnknownOp => write!(f, "unknown op"),
        }
    }
}

impl std::error::Error for CommandError {}

impl From<StoreError> for CommandError {
    fn from(value: StoreError) -> Self {
        Self::Store(value)
    }
}

/// What a handler changed. The caller turns this into a snapshot projection;
/// the host does not invent snapshot keys here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// `space.key.save` / `space.key.clear`: whether a key is now configured.
    KeyConfigured(bool),
    /// `app.language`: the locale that was accepted.
    Language(String),
}

/// Mutable host state that handlers may touch.
#[derive(Debug, Default, Clone)]
pub struct HostState {
    /// The active UI locale, once `app.language` has accepted one.
    pub locale: Option<String>,
}

/// The ops [`dispatch`] can actually serve. The gate cross-checks this against
/// [`crate::registry::REGISTRY`]; the two must agree.
pub const IMPLEMENTED_OPS: &[&str] = &["app.language", "space.key.clear", "space.key.save"];

/// Serve one command.
pub fn dispatch(
    op: &str,
    fields: &FieldMap,
    store: &SecretStore,
    state: &mut HostState,
) -> Result<Outcome, CommandError> {
    match op {
        // `UnityProductSettings.swift`: `guard let key = value["apiKey"] as? String`,
        // then `marbleAPIKey.replacementKey = key; marbleAPIKey.save()`.
        "space.key.save" => {
            let key = fields
                .get("apiKey")
                .and_then(FieldValue::as_text)
                .ok_or(CommandError::MissingField("apiKey"))?;
            let trimmed = key.trim();
            // `MarbleAPIKeyProvider.save` throws on empty after trimming; the
            // same refusal belongs here.
            if trimmed.is_empty() {
                return Err(CommandError::InvalidField("apiKey"));
            }
            store.write(MARBLE_KEY_NAME, trimmed)?;
            Ok(Outcome::KeyConfigured(true))
        }
        // `marble.clear()`.
        "space.key.clear" => {
            store.clear(MARBLE_KEY_NAME)?;
            Ok(Outcome::KeyConfigured(false))
        }
        // `guard let locale = value["locale"] as? String,
        //  ["zh-CN", "en", "ja"].contains(locale)`.
        "app.language" => {
            let locale = fields
                .get("locale")
                .and_then(FieldValue::as_text)
                .ok_or(CommandError::MissingField("locale"))?;
            if !ALLOWED_LOCALES.contains(&locale) {
                return Err(CommandError::InvalidField("locale"));
            }
            state.locale = Some(locale.to_owned());
            Ok(Outcome::Language(locale.to_owned()))
        }
        _ => Err(CommandError::NotImplemented(
            crate::registry::reason_for(op).unwrap_or("no handler in this host"),
        )),
    }
}
