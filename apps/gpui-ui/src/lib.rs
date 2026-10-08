#![recursion_limit = "256"]
//! The 2D UI layer that floats over the rendered Unity space.
//!
//! Every surface below is a gpui-kit view that the product host mounts, and
//! every one of them is written against the same foundation:
//!
//! - [`ui_tokens`] — typography, spacing, and the fixed dark chrome that an
//!   overlay panel must use instead of the system theme;
//! - [`primitives`] — the shared chrome/type/control builders, so one visual
//!   role has one definition across the whole layer;
//! - [`chat`], [`settings`], [`inbox`], [`stage_panels`] — the surfaces
//!   themselves, each aligned to its original source, and [`shell`] — the fixed
//!   floating bar and destination button that the host mounts;
//! - [`state`] — UI-only state machines (transport lives in the host);
//! - [`projective_card`] — the off-screen card projection used by the program
//!   rail, and [`i18n`] — the original localization tables.
//!
//! Dynamic lyrics are deliberately **not** part of this layer: they stay on the
//! native GPU path ([`lyrics`]) because they need glyph deformation and
//! per-mode effects that a plain 2D layer cannot reproduce.
pub mod chat;
pub mod i18n;
pub mod inbox;
pub mod lyrics;
pub mod primitives;
pub mod projective_card;
pub mod settings;
pub mod shell;
pub mod stage_panels;
pub mod state;
pub mod ui_tokens;

pub use chat::{safe_asr_error_code, ResidentChatPane};
