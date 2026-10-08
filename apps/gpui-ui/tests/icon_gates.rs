//! Two mechanical gates that keep the overlay layer **icon-only** and
//! **paintable**.
//!
//! ## Gate 1 — a control must not draw words
//!
//! Kit's `.label(` is the API that paints text on the face of a control. In this
//! layer a control's face is an icon; the words belong in the tooltip and the
//! accessibility label (`primitives::icon_button`, `shell.rs`). Exactly three
//! classes of text are allowed, and each is decided from the **code context** of
//! the `.label(` call, not from a keyword on its line:
//!
//! 1. a dialog's confirm/cancel/danger action — the enclosing function opens a
//!    dialog (`open_dialog(`), the chain closes one (`close_dialog`), or the
//!    chain carries `.danger()`;
//! 2. a menu item or menu trigger — the chain opens a `.dropdown_menu(` /
//!    `.dropdown_caret(`, or the enclosing function is a `_menu`;
//! 3. row/content text — kit's `Switch` renders its label as the settings row's
//!    own text, and a `TabBar` whose faces are runtime data (see
//!    [`DATA_TAB_BARS`]) is a projection of the data, not control copy.
//!
//! Everything else fails with `path:line`.
//!
//! ## Gate 2 — a control's icon must actually paint
//!
//! `IconName` names every lucide icon, but a name only paints when the asset
//! source the product registers embeds it:
//!
//! * `gpui_kit::assets::AllAssets` embeds the whole catalog (1830 icons);
//! * `gpui_kit::assets::Assets`, gpui-kit's *default component bundle*, embeds
//!   only the 106 icons in `crates/assets/default-icons.txt` at the pinned
//!   revision.
//!
//! The original v12 "bottom bar icons are empty" defect is exactly a layer that
//! used a name its registered source does not embed: it compiles and paints
//! nothing. Gate 2 therefore reads the registration out of
//! `apps/gpui-app/src/main.rs` and loads **every** `IconName::` literal in the
//! layer through that source. It also requires every icon outside the default
//! component bundle to be recorded in [`CATALOG_ONLY`] with a reason, so picking
//! an icon that only the full catalog carries is a reviewed decision rather than
//! an accident.

use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Source discovery
// ---------------------------------------------------------------------------

/// `apps/gpui-ui`.
fn ui_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// The checkout root (the directory that holds `apps/`).
fn repo_root() -> PathBuf {
    ui_dir()
        .parent()
        .and_then(Path::parent)
        .expect("apps/gpui-ui lives in <root>/apps")
        .to_path_buf()
}

/// `apps/gpui-app/src/main.rs` — the product's entry point, and the only place
/// that decides which asset source the layer's icons are loaded from.
fn app_main() -> PathBuf {
    repo_root().join("apps/gpui-app/src/main.rs")
}

fn collect_rust(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_rust(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            out.push(path);
        }
    }
}

/// Every source file the icon-only rule governs: the whole overlay layer plus the
/// product entry point that mounts it.
fn layer_sources() -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_rust(&ui_dir().join("src"), &mut files);
    files.push(app_main());
    files.sort();
    files
}

fn display_path(path: &Path) -> String {
    path.strip_prefix(repo_root())
        .unwrap_or(path)
        .display()
        .to_string()
}

// ---------------------------------------------------------------------------
// Masking: code only
// ---------------------------------------------------------------------------

/// Blank out comments and the *contents* of string/char literals, preserving
/// byte length, newlines and the quote delimiters themselves.
///
/// `.label(` in a comment, a doc example or an assertion's message is not a
/// control that draws words; `.label(` in code is. Masking (rather than
/// line-based filtering) is what lets the gate read the real chain — a
/// `close_dialog` written inside an `on_click` closure still counts as context —
/// and keeping the delimiters is what keeps `TabBar::new("…")` findable.
fn mask(source: &str) -> String {
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum State {
        Code,
        Line,
        Block(u32),
        Str,
    }

    let bytes = source.as_bytes();
    let mut out = bytes.to_vec();
    let mut state = State::Code;
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        match state {
            State::Code => {
                if c == b'/' && bytes.get(i + 1) == Some(&b'/') {
                    out[i] = b' ';
                    out[i + 1] = b' ';
                    i += 2;
                    state = State::Line;
                } else if c == b'/' && bytes.get(i + 1) == Some(&b'*') {
                    out[i] = b' ';
                    out[i + 1] = b' ';
                    i += 2;
                    state = State::Block(1);
                } else if let Some((body, skip)) = raw_string_range(bytes, i) {
                    for byte in &mut out[body.0..body.1] {
                        if *byte != b'\n' {
                            *byte = b' ';
                        }
                    }
                    i = skip;
                } else if c == b'"' {
                    i += 1;
                    state = State::Str;
                } else if c == b'\'' {
                    // A char literal is masked; a lifetime (`'a`) is code.
                    let mut j = i + 1;
                    let mut escaped = false;
                    let mut closed = false;
                    while j < bytes.len() && j <= i + 4 {
                        match bytes[j] {
                            _ if escaped => escaped = false,
                            b'\\' => escaped = true,
                            b'\'' => {
                                closed = true;
                                break;
                            }
                            b'\n' => break,
                            _ => {}
                        }
                        j += 1;
                    }
                    if closed {
                        for byte in &mut out[i + 1..j] {
                            *byte = b' ';
                        }
                        i = j + 1;
                    } else {
                        i += 1;
                    }
                } else {
                    i += 1;
                }
            }
            State::Line => {
                if c == b'\n' {
                    state = State::Code;
                } else {
                    out[i] = b' ';
                }
                i += 1;
            }
            State::Block(depth) => {
                if c == b'/' && bytes.get(i + 1) == Some(&b'*') {
                    out[i] = b' ';
                    out[i + 1] = b' ';
                    i += 2;
                    state = State::Block(depth + 1);
                } else if c == b'*' && bytes.get(i + 1) == Some(&b'/') {
                    out[i] = b' ';
                    out[i + 1] = b' ';
                    i += 2;
                    state = if depth == 1 {
                        State::Code
                    } else {
                        State::Block(depth - 1)
                    };
                } else {
                    if c != b'\n' {
                        out[i] = b' ';
                    }
                    i += 1;
                }
            }
            State::Str => {
                if c == b'\\' {
                    out[i] = b' ';
                    if let Some(next) = bytes.get(i + 1) {
                        if *next != b'\n' {
                            out[i + 1] = b' ';
                        }
                        i += 2;
                    } else {
                        i += 1;
                    }
                } else if c == b'"' {
                    i += 1;
                    state = State::Code;
                } else {
                    if c != b'\n' {
                        out[i] = b' ';
                    }
                    i += 1;
                }
            }
        }
    }
    String::from_utf8(out).expect("masking preserves UTF-8")
}

/// If a raw string (`r"…"`, `r#"…"#`, `br#"…"#`) starts at `start`, return the
/// body's range and the offset just past the closing delimiter; the delimiters
/// stay in the masked text.
fn raw_string_range(bytes: &[u8], start: usize) -> Option<((usize, usize), usize)> {
    let mut i = start;
    if bytes.get(i) == Some(&b'b') {
        i += 1;
    }
    if bytes.get(i) != Some(&b'r') {
        return None;
    }
    i += 1;
    let mut hashes = 0usize;
    while bytes.get(i) == Some(&b'#') {
        hashes += 1;
        i += 1;
    }
    if bytes.get(i) != Some(&b'"') {
        return None;
    }
    let body_start = i + 1;
    let mut cursor = body_start;
    while cursor < bytes.len() {
        if bytes[cursor] == b'"'
            && bytes
                .get(cursor + 1..cursor + 1 + hashes)
                .is_some_and(|tail| tail.iter().all(|byte| *byte == b'#'))
        {
            return Some(((body_start, cursor), cursor + 1 + hashes));
        }
        cursor += 1;
    }
    Some(((body_start, bytes.len()), bytes.len()))
}

fn line_number(masked: &str, offset: usize) -> usize {
    masked[..offset].matches('\n').count() + 1
}

fn line_start(masked: &str, offset: usize) -> usize {
    masked[..offset].rfind('\n').map_or(0, |index| index + 1)
}

// ---------------------------------------------------------------------------
// Gate 1 — icon-only controls
// ---------------------------------------------------------------------------

/// The constructors whose builder chain a `.label(` belongs to.
const CHAIN_HEADS: &[&str] = &[
    "Button::new(",
    "Tab::new(",
    "Switch::new(",
    "MenuItem::new(",
    "PopupMenu::new(",
    "Toggle::new(",
];

/// The text a `.label(` draws is allowed only inside these code contexts.
///
/// Each entry names the **code** that decides the exemption, never a word on the
/// same line as the `.label(`.
#[derive(Debug)]
enum Allowed {
    /// A dialog's confirm/cancel/danger action: words there are a safety
    /// requirement (the person must be able to tell "永久删除" from "取消").
    DialogAction,
    /// A menu item or a menu trigger, whose face is the menu's own vocabulary.
    Menu,
    /// kit's `Switch` renders its label as the settings row's text beside the
    /// toggle; that is row content, and no icon names a setting.
    SwitchRowLabel,
    /// A tab bar whose faces are runtime data (names supplied by the host).
    DataTabBar,
    /// A recorded, individually reviewed exception (see [`EXEMPT_SITES`]).
    ReviewedSite,
}

impl Allowed {
    fn reason(&self) -> &'static str {
        match self {
            Self::DialogAction => {
                "dialog confirm/cancel/danger action — the words are the safety requirement"
            }
            Self::Menu => "menu item / menu trigger — the menu's own vocabulary",
            Self::SwitchRowLabel => {
                "kit Switch renders its label as the settings row's text beside the toggle"
            }
            Self::DataTabBar => "the tab faces are runtime data, not control copy",
            Self::ReviewedSite => "recorded in EXEMPT_SITES with a reason",
        }
    }
}

/// Tab bars whose faces are runtime data. Keyed by the `TabBar::new("<id>")`.
const DATA_TAB_BARS: &[(&str, &str)] = &[
    (
        "motion-categories",
        "faces are the motion category names supplied by the host",
    ),
    (
        "prop-hold-points",
        "faces are the hold-point names supplied by the host",
    ),
];

/// Sites the gate must not fail on, matched by file **and** contiguous code line
/// and enclosing function, so the exemption cannot silently widen.
///
/// The lyrics overlay is outside this change's editable set (a parallel
/// workstream owns it), so its two control labels are recorded here instead of
/// being silently skipped; `primitives::capsule_button` is the original's
/// "停止说话" text pill, retained by design (a separate assertion below proves it
/// has no call sites outside its own module).
const EXEMPT_SITES: &[(&str, &str, &str, &str)] = &[
    (
        "apps/gpui-ui/src/lyrics.rs",
        "render",
        ".label(\"播放\")",
        "hard constraint: lyrics.rs is not editable in this change",
    ),
    (
        "apps/gpui-ui/src/lyrics.rs",
        "render",
        ".label(\"×\")",
        "hard constraint: lyrics.rs is not editable in this change",
    ),
    (
        "apps/gpui-ui/src/primitives.rs",
        "capsule_button",
        ".label(label.clone())",
        "the original's 停止说话 text pill, retained by design; new controls must use icon_button",
    ),
];

fn chain_head_start(masked: &str, offset: usize) -> usize {
    let before = &masked[..offset];
    CHAIN_HEADS
        .iter()
        .filter_map(|head| before.rfind(head))
        .max()
        .unwrap_or_else(|| line_start(masked, offset))
}

/// The builder chain the `.label(` sits in: from its constructor up to the first
/// statement terminator, so a `close_dialog` inside the chain's `on_click`
/// closure counts as context.
fn chain_text(masked: &str, offset: usize) -> String {
    let start = chain_head_start(masked, offset);
    let end = masked[offset..]
        .find(';')
        .map(|delta| offset + delta + 1)
        .or_else(|| masked[offset..].find('\n').map(|delta| offset + delta))
        .unwrap_or(masked.len());
    masked[start..end].to_string()
}

fn chain_head_name(masked: &str, offset: usize) -> String {
    let start = chain_head_start(masked, offset);
    let rest = &masked[start..];
    rest.split("::new(").next().unwrap_or("").trim().to_string()
}

/// The enclosing function's name and body (masked).
fn enclosing_fn(masked: &str, offset: usize) -> (String, String) {
    let mut fn_start = 0;
    let mut cursor = 0;
    while cursor < offset {
        let end = masked[cursor..]
            .find('\n')
            .map_or(masked.len(), |delta| cursor + delta);
        let trimmed = masked[cursor..end].trim_start();
        if trimmed.contains("fn ")
            && (trimmed.starts_with("fn ")
                || trimmed.starts_with("pub")
                || trimmed.starts_with("async"))
        {
            fn_start = cursor;
        }
        cursor = end + 1;
    }
    let header = masked[fn_start..].lines().next().unwrap_or("");
    let name = header
        .split("fn ")
        .nth(1)
        .and_then(|rest| rest.split(['(', '<']).next())
        .unwrap_or("")
        .trim()
        .to_string();
    let indent = header.len() - header.trim_start().len();
    let mut body_end = masked.len();
    let mut cursor = fn_start;
    while let Some(next) = masked[cursor..].find('\n') {
        cursor += next + 1;
        let line = masked[cursor..].lines().next().unwrap_or("");
        if line.trim() == "}" && line.len() - line.trim_start().len() <= indent {
            body_end = cursor;
            break;
        }
    }
    (name, masked[fn_start..body_end].to_string())
}

/// The id of the nearest preceding `TabBar::new("…")`, read from the **raw**
/// source because the id lives inside a string literal (which masking blanks).
fn nearest_tab_bar(raw: &str, offset: usize) -> Option<String> {
    let key = "TabBar::new(\"";
    let start = raw[..offset].rfind(key)? + key.len();
    let end = raw[start..].find('"')? + start;
    Some(raw[start..end].to_string())
}

/// Why this `.label(` is allowed, or `None` when the control must be icon-only.
///
/// `masked` is the code-only view used to read the chain, and `raw` is the
/// unmasked source, needed for the two decisions that depend on a string
/// literal: the tab bar's id and the recorded exceptions' Chinese copy.
fn allowed_reason(path: &str, masked: &str, raw: &str, offset: usize) -> Option<Allowed> {
    let chain = chain_text(masked, offset);
    let (fn_name, fn_body) = enclosing_fn(masked, offset);
    let head = chain_head_name(masked, offset);

    // 1. dialogs: the enclosing function opens one, or the chain closes one.
    if chain.contains("close_dialog")
        || chain.contains("open_dialog")
        || fn_body.contains("open_dialog(")
        || fn_name.contains("dialog")
    {
        return Some(Allowed::DialogAction);
    }
    // 1b. the destructive-action chain, which the original paints with words.
    if chain.contains(".danger()") {
        return Some(Allowed::DialogAction);
    }
    // 2. menus: an item's face, or a trigger whose face names the menu.
    if chain.contains("dropdown_caret(")
        || chain.contains("dropdown_menu(")
        || head == "MenuItem"
        || head == "PopupMenu"
        || fn_name.ends_with("_menu")
    {
        return Some(Allowed::Menu);
    }
    // 3a. kit's Switch paints its label as the row's text, not on the toggle.
    if head == "Switch" {
        return Some(Allowed::SwitchRowLabel);
    }
    // 3b. a tab bar over runtime data.
    if let Some(id) = nearest_tab_bar(raw, offset) {
        if DATA_TAB_BARS.iter().any(|(key, _)| *key == id) {
            return Some(Allowed::DataTabBar);
        }
    }
    // 4. the recorded, reviewed exceptions.
    let raw_line = raw[line_start(masked, offset)..]
        .lines()
        .next()
        .unwrap_or("")
        .trim();
    if EXEMPT_SITES.iter().any(|(file, function, text, _)| {
        *file == path && *function == fn_name.as_str() && *text == raw_line
    }) {
        return Some(Allowed::ReviewedSite);
    }
    None
}

#[test]
fn every_control_in_the_layer_is_icon_only() {
    let mut failures = Vec::new();
    let mut allowed = Vec::new();
    for file in layer_sources() {
        let Ok(source) = fs::read_to_string(&file) else {
            continue;
        };
        let path = display_path(&file);
        let masked = mask(&source);
        for (offset, _) in masked.match_indices(".label(") {
            let start = line_start(&masked, offset);
            let raw_line = source[start..]
                .lines()
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
            match allowed_reason(&path, &masked, &source, offset) {
                Some(reason) => allowed.push(format!(
                    "{}:{}: allowed — {}",
                    path,
                    line_number(&masked, offset),
                    reason.reason()
                )),
                None => failures.push(format!(
                    "{}:{}: a control draws words instead of an icon: {}",
                    path,
                    line_number(&masked, offset),
                    raw_line
                )),
            }
        }
    }
    for line in &allowed {
        // Visible with `cargo test -- --nocapture`; the exemptions stay auditable.
        eprintln!("icon-only gate: {line}");
    }
    assert!(
        failures.is_empty(),
        "icon-only gate FAILED: {} control(s) render text; put the words in the tooltip and the accessibility label, or record the site in EXEMPT_SITES with a reason:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// `capsule_button` is the one remaining text pill in the layer. It exists only
/// because the original shows words on it during speech, so the rule is that no
/// new control may call it: this assertion is what keeps the exception from
/// spreading.
#[test]
fn the_retained_text_pill_has_no_call_sites() {
    let mut failures = Vec::new();
    for file in layer_sources() {
        let path = display_path(&file);
        if path.ends_with("src/primitives.rs") {
            continue;
        }
        let Ok(source) = fs::read_to_string(&file) else {
            continue;
        };
        let masked = mask(&source);
        for (offset, _) in masked.match_indices("capsule_button(") {
            failures.push(format!(
                "{}:{}: a control calls capsule_button (the retained 停止说话 text pill); use primitives::icon_button",
                path,
                line_number(&masked, offset)
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "icon-only gate FAILED: the text pill may not be used by new controls:\n{}",
        failures.join("\n")
    );
}

// ---------------------------------------------------------------------------
// Gate 2 — every icon the layer names is embedded by the registered source
// ---------------------------------------------------------------------------

/// Icons whose names are in the full catalog but **not** in gpui-kit's default
/// component bundle (`crates/assets/default-icons.txt`, 106 icons).
///
/// The product registers `AllAssets`, so these paint; the allow-list exists so
/// that reaching outside the default bundle is a reviewed decision. Each entry
/// must still be referenced (below), which is what stops the list from rotting.
const CATALOG_ONLY: &[(&str, &str)] = &[
    (
        "Activity",
        "the motion row's status glyph; the default bundle has no waveform/pulse icon",
    ),
    (
        "Apple",
        "the platform mark on a music provider row; the default bundle has no brand icon",
    ),
    (
        "AudioWaveform",
        "the original's waveform.circle.fill while the microphone listens; no bundled equivalent",
    ),
    (
        "Box",
        "the original's shippingbox while a prop is placed; the default bundle has no box",
    ),
    (
        "Circle",
        "the original's circle status dot; the default bundle only ships circle-* variants",
    ),
    (
        "CirclePause",
        "the original's pause.circle on the autonomy banner; only `pause` is bundled",
    ),
    (
        "Hand",
        "the original's hand.raised when autonomy is off; the default bundle has no hand",
    ),
    (
        "Hourglass",
        "the original's hourglass while a request is pending/connecting; no bundled equivalent",
    ),
    (
        "Keyboard",
        "the original's keyboard mark on the 快捷键 settings tab; the default bundle ships no keyboard icon",
    ),
    (
        "ListMusic",
        "the original's music.note.list for a playlist row; the default bundle has no music glyph",
    ),
    (
        "MousePointerClick",
        "the original's hand.tap for the screen-annotation control; no bundled equivalent",
    ),
    (
        "Music",
        "music.note for the player/音乐 entries; gpui-kit's default bundle ships no music glyph",
    ),
    (
        "PersonStanding",
        "the original's figure.stand for the character entry; only `user` is bundled",
    ),
    (
        "Radio",
        "the original's dot.radiowaves for the radio plugin; no bundled equivalent",
    ),
    (
        "Repeat",
        "the original's repeat arrow on a looping motion; the default bundle has no repeat",
    ),
    (
        "SquareStack",
        "the original's square.stack.3d.up for the props control; no bundled equivalent",
    ),
    (
        "Terminal",
        "the original's terminal mark on the 策划引擎 row; only `square-terminal` is bundled",
    ),
    (
        "UserRound",
        "the original's person.crop.circle on a resident row; only `circle-user`/`user` are bundled",
    ),
    (
        "Video",
        "the original's video mark on the bound-video prompt; the default bundle has no video glyph",
    ),
    (
        "Volume2",
        "the original's speaker.wave.2.fill while speaking; the default bundle has no volume icon",
    ),
    (
        "Archive",
        "the ownership row's ended/archived status glyph; the default bundle has no archive",
    ),
    (
        "Captions",
        "the 字幕特效 (lyrics effects) group mark; the default bundle has no captions glyph",
    ),
    (
        "CircleArrowDown",
        "the ownership row's awaiting-claim status glyph; the default bundle has no circle-arrow",
    ),
    (
        "CirclePlay",
        "the activity row's not-active status glyph; the default bundle ships only plain `play`",
    ),
    (
        "Film",
        "the MV 场景 (music video) group mark; the default bundle has no film glyph",
    ),
    (
        "Grid3x3",
        "the 3D 点阵 (point cloud) group mark; the default bundle has no grid glyph",
    ),
    (
        "Layers",
        "the prop editor's layered-placement status glyph; the default bundle has no layers icon",
    ),
    (
        "Package",
        "the ownership row's in-inventory status glyph; the default bundle has no package",
    ),
    (
        "Sparkles",
        "the player rail's loading/notice mark; the default bundle has no sparkle glyph",
    ),
    (
        "SunDim",
        "the 粒子大小 (particle size) group mark; the default bundle ships only the full `sun`",
    ),
    (
        "VideoOff",
        "the player's video-disabled status glyph; the default bundle has no video glyph",
    ),
    (
        "WifiOff",
        "the original's wifi.exclamationmark on the connectivity banner; no bundled equivalent",
    ),
    (
        "X",
        "lucide's `x` close glyph; the default bundle's close icon is `close`",
    ),
];

/// The asset source `main()` registers, named exactly as written in the source.
fn registered_asset_source(main_rs: &str) -> String {
    let key = "with_assets(gpui_kit::assets::";
    let start = main_rs
        .find(key)
        .unwrap_or_else(|| panic!("apps/gpui-app/src/main.rs no longer registers an asset source with `{key}`"))
        + key.len();
    let rest = &main_rs[start..];
    let end = rest
        .find([')', ','])
        .unwrap_or_else(|| panic!("unterminated asset source registration"));
    rest[..end].trim().to_string()
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Source {
    /// `gpui_kit::assets::AllAssets` — the whole catalog.
    All,
    /// `gpui_kit::assets::Assets` — gpui-kit's default component bundle.
    Default,
}

impl Source {
    fn parse(name: &str) -> Self {
        match name {
            "AllAssets" => Self::All,
            "Assets" => Self::Default,
            other => panic!(
                "the product registers `{other}` as its asset source; the packaging gate cannot tell which icons paint"
            ),
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::All => "gpui_kit::assets::AllAssets",
            Self::Default => "gpui_kit::assets::Assets (the default component bundle)",
        }
    }

    fn paths(self) -> BTreeSet<String> {
        use gpui_kit::AssetSource as _;
        let listed = match self {
            Self::All => gpui_kit::assets::AllAssets.list("icons/"),
            Self::Default => gpui_kit::assets::Assets.list("icons/"),
        }
        .expect("the embedded asset source lists its icons");
        listed.into_iter().map(|path| path.to_string()).collect()
    }

    fn load(self, path: &str) -> Option<Cow<'static, [u8]>> {
        use gpui_kit::AssetSource as _;
        match self {
            Self::All => gpui_kit::assets::AllAssets.load(path),
            Self::Default => gpui_kit::assets::Assets.load(path),
        }
        .expect("the embedded asset source loads an icon")
    }
}

/// The names the layer uses for gpui-kit's icon enum: `IconName`, plus every
/// alias a source declares (`use gpui_kit::assets::IconName as AssetIcon;` in
/// the stage panels). Scanning only `IconName::` would miss every aliased use —
/// which is how the first version of this gate let `AssetIcon::Zap` through.
fn icon_enum_names(masked: &str) -> BTreeSet<String> {
    let mut names: BTreeSet<String> = std::iter::once("IconName".to_string()).collect();
    for (offset, _) in masked.match_indices("IconName as ") {
        let rest = &masked[offset + "IconName as ".len()..];
        let alias: String = rest
            .chars()
            .take_while(|ch| ch.is_ascii_alphanumeric() || *ch == '_')
            .collect();
        if !alias.is_empty() {
            names.insert(alias);
        }
    }
    names
}

/// Every icon literal in the layer, with its file, line and the icon it resolves
/// to. Comments and string literals are masked out first, so a mention in prose
/// is not an icon the layer paints; aliased uses (`AssetIcon::X`) count too.
fn icon_literals() -> Vec<(String, usize, String, gpui_kit::assets::IconName)> {
    // The catalog is keyed by the *variant* name (`IconName` derives `Debug`),
    // which is exact: slugifying the name is not, because the catalog is not a
    // pure CamelCase -> kebab-case transform (`Grid3x3` is `icons/grid-3x3.svg`).
    let by_variant: BTreeMap<String, gpui_kit::assets::IconName> = gpui_kit::assets::IconName::ALL
        .iter()
        .copied()
        .map(|icon| (format!("{icon:?}"), icon))
        .collect();
    let mut found = Vec::new();
    for file in layer_sources() {
        let Ok(source) = fs::read_to_string(&file) else {
            continue;
        };
        let path = display_path(&file);
        let masked = mask(&source);
        let mut hits: Vec<(usize, String)> = Vec::new();
        for enum_name in icon_enum_names(&masked) {
            let marker = format!("{enum_name}::");
            for (offset, _) in masked.match_indices(&marker) {
                let rest = &masked[offset + marker.len()..];
                let name: String = rest
                    .chars()
                    .take_while(|ch| ch.is_ascii_alphanumeric() || *ch == '_')
                    .collect();
                if !name.is_empty() {
                    hits.push((offset, name));
                }
            }
        }
        hits.sort();
        for (offset, name) in hits {
            match by_variant.get(&name) {
                Some(icon) => found.push((path.clone(), line_number(&masked, offset), name, *icon)),
                None => panic!(
                    "{}:{}: `{name}` is not a variant of gpui_kit::assets::IconName; the control would not compile",
                    path,
                    line_number(&masked, offset)
                ),
            }
        }
    }
    found
}

/// Every icon the layer names must be embedded by the source the product
/// registers — otherwise it compiles and paints an empty square, which is the
/// original v12 "bottom bar icons are empty" defect.
#[test]
fn every_icon_the_layer_names_is_embedded_by_the_registered_source() {
    let main_rs = fs::read_to_string(app_main()).expect("read the product entry point");
    let registered = registered_asset_source(&main_rs);
    let source = Source::parse(&registered);
    let embedded = source.paths();
    let mut failures = Vec::new();
    let mut seen = BTreeSet::new();
    for (path, line, name, icon) in icon_literals() {
        seen.insert(name.clone());
        let icon_path = icon.path().to_string();
        if !embedded.contains(&icon_path) {
            failures.push(format!(
                "{path}:{line}: `{name}` -> {icon_path} is not embedded by {}",
                source.label()
            ));
            continue;
        }
        match source.load(&icon_path) {
            Some(bytes) => {
                if !String::from_utf8_lossy(&bytes).contains("<svg") {
                    failures.push(format!(
                        "{path}:{line}: `{name}` -> {icon_path} is not an SVG"
                    ));
                }
            }
            None => failures.push(format!(
                "{path}:{line}: `{name}` -> {icon_path} did not load from {}",
                source.label()
            )),
        }
    }
    assert!(
        !seen.is_empty(),
        "the layer names no icons at all; the packaging gate is not looking at the real sources"
    );
    assert!(
        failures.is_empty(),
        "icon packaging gate FAILED: {} icon(s) the layer names would paint blank.\nIf the product is meant to register the full catalog, keep `.with_assets(gpui_kit::assets::AllAssets)`; otherwise replace each icon with one from gpui-kit's default component bundle:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// Reaching outside gpui-kit's default component bundle must be reviewed. The
/// default bundle is what a window gets when it registers `Assets` (106 icons);
/// anything else needs an entry in [`CATALOG_ONLY`] that says why.
#[test]
fn icons_outside_the_default_bundle_are_reviewed() {
    let default: BTreeSet<String> = Source::Default.paths();
    let mut failures = Vec::new();
    let mut used: BTreeSet<String> = BTreeSet::new();
    for (path, line, name, icon) in icon_literals() {
        if default.contains(icon.path().as_ref()) {
            continue;
        }
        used.insert(name.clone());
        if !CATALOG_ONLY.iter().any(|(allowed, _)| *allowed == name) {
            failures.push(format!(
                "{path}:{line}: `{name}` is outside gpui-kit's default component bundle; pick a bundled icon from `crates/assets/default-icons.txt`, or add `{name}` to CATALOG_ONLY with the reason it must paint"
            ));
        }
    }
    for (name, _) in CATALOG_ONLY {
        if !used.contains(*name) {
            failures.push(format!(
                "CATALOG_ONLY lists `{name}`, but nothing in the layer uses it; delete the stale exception"
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "icon packaging gate FAILED: the catalog-only allow-list and the layer disagree:\n{}",
        failures.join("\n")
    );
}
