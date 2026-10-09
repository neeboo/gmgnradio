//! Mechanical gate: the overlay layer must never take a control's chrome from
//! the **system theme**.
//!
//! `gpui-kit`'s `Button` variants resolve their resting fill — and their hover
//! and pressed surfaces — through `cx.theme()` (`crates/component/src/button/
//! button.rs`: `bg_color`, `outline_background`, `hovered`, `active`):
//!
//! * `Button::primary()` fills with `theme.tokens.button_primary`
//!   (`button.primary.background`, `#fafafa` under the dark theme). That token
//!   is the white control that painted through the media panel's inbox pane:
//!   the pane is fixed dark (`ui_tokens::scene::CARD_BG`/`PANEL_BG`) and a
//!   near-white fill cannot belong to it;
//! * `.secondary()`, `.danger()`, `.warning()`, `.success()` and `.info()` read
//!   the same token family, and the implicit `Default` variant is
//!   `theme.tokens.button`;
//! * `.custom(ButtonCustomVariant::new(cx))` starts from `cx.theme()`;
//! * a bare `cx.theme()` (or an `ActiveTheme` import, which is what makes it
//!   resolve) is the same dependency spelled out.
//!
//! A surface that floats over the rendered space must therefore never call any
//! of them: controls are built from the shared [`primitives`] helpers, whose
//! resting surface is transparent and whose colours are the fixed `scene`
//! tokens. A destructive control expresses danger with
//! `ui_tokens::stage::DANGER_TEXT` instead of `.danger()`.
//!
//! The scan reads **code only**: comments are masked, so explaining this rule in
//! a doc comment (as `shell.rs` and `primitives.rs` do) is not a violation, and
//! string-literal bodies are masked, so quoting a needle in copy is not one
//! either.
//!
//! `ALLOWED` is the complete exemption list and every entry states why it is
//! safe. It is deliberately tiny: only `.custom(..)` sites that build a variant
//! out of fixed overlay tokens, plus one `.danger()` in `stage_panels/**`, a
//! tree this change may not edit. `cx.theme()`/`ActiveTheme` have **no**
//! exemptions anywhere, so an exempted file still cannot read the theme.
//!
//! [`primitives`]: ../src/primitives.rs

use std::fs;
use std::path::{Path, PathBuf};

/// The theme-derived control APIs. Every one of them resolves through
/// `cx.theme()` inside gpui-kit; none of them may appear in this layer.
const BANNED: &[&str] = &[
    ".primary()",
    ".secondary()",
    ".danger()",
    ".warning()",
    ".success()",
    ".info()",
    ".custom(",
    "cx.theme()",
    "ActiveTheme",
];

/// One reviewed exemption: `needle` may appear in `file` at most `max` times.
struct Allowance {
    /// Full path from the repository root, e.g. `apps/gpui-ui/src/primitives.rs`
    /// (the gate scans more than one tree — see [`scan_roots`]).
    file: &'static str,
    needle: &'static str,
    max: usize,
    reason: &'static str,
}

/// The complete exemption list. Each entry is checked for a maximum count *and*
/// for staleness (an exemption nothing matches fails too), so it cannot rot.
const ALLOWED: &[Allowance] = &[
    Allowance {
        file: "apps/gpui-ui/src/primitives.rs",
        needle: ".custom(",
        max: 1,
        reason: "`primary_circle_button` builds its one custom variant from the fixed \
                 `scene::FILL` / `scene::FILL_DISABLED` / `scene::ON_FILL` tokens; `cx.theme()` \
                 stays banned in this file like every other.",
    },
    Allowance {
        file: "apps/gpui-ui/src/settings.rs",
        needle: ".custom(",
        max: 1,
        reason: "the shortcut cell's recording tint: four `rgba(scene::ACCENT…)` values at fixed \
                 alphas, so nothing is inherited from the theme.",
    },
    Allowance {
        file: "apps/gpui-ui/src/stage_panels.rs",
        needle: ".custom(",
        max: usize::MAX,
        reason: "`stage_panels/**` is owned by another line and outside this change's edit scope; \
                 every call there is `scene_variant(cx, ..)` with explicit fill/hover/text \
                 tokens, and a theme read would still be caught above.",
    },
    Allowance {
        file: "apps/gpui-ui/src/stage_panels/props.rs",
        needle: ".custom(",
        max: usize::MAX,
        reason: "same `scene_variant(cx, ..)` recipe as `stage_panels.rs`.",
    },
    Allowance {
        file: "apps/gpui-ui/src/stage_panels/program.rs",
        needle: ".custom(",
        max: usize::MAX,
        reason: "same `scene_variant(cx, ..)` recipe as `stage_panels.rs`.",
    },
    Allowance {
        file: "apps/gpui-ui/src/stage_panels/props.rs",
        needle: ".danger()",
        max: 1,
        reason: "the 永久删除 confirm dialog's kit Danger variant. `stage_panels/**` is outside \
                 this change's edit scope, so the site is recorded instead of converted; the cap \
                 of one is what stops it spreading to controls that were not reviewed.",
    },
];

fn src_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
}

/// Every tree that **ships the overlay**: the layer itself, and the Unity
/// overlay probe, which embeds the same panels in the same window.
///
/// The probe used to sit outside this gate, and that is exactly where three
/// `cx.theme()` reads survived the 主题 cleanup: the root's text colour and the
/// queue-error toast's background/danger. A palette rule that only covers half
/// of the surfaces the product renders is a rule with a hole, so the probe is
/// scanned too.
///
/// The probe needs **no** exemption: it names none of the banned control
/// variants and, after the 2026-10-09 fix, no bare `cx.theme()` in code. If a
/// real need appears, it is recorded in [`ALLOWED`] with a reason like any
/// other.
fn scan_roots() -> Vec<(PathBuf, &'static str)> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let repo = root
        .parent()
        .and_then(Path::parent)
        .expect("apps/gpui-ui lives in <repo>/apps");
    vec![
        (src_dir(), "apps/gpui-ui/src/"),
        (
            repo.join("tools/fixtures/gpui-unity-overlay-probe/src"),
            "tools/fixtures/gpui-unity-overlay-probe/src/",
        ),
    ]
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

/// End offset (exclusive) of the raw string starting at `start` (`r"…"`,
/// `r#"…"#`, `r##"…"##`), or `None` when `r` starts an identifier instead.
fn raw_string_end(bytes: &[u8], start: usize) -> Option<usize> {
    let mut j = start + 1;
    let mut hashes = 0usize;
    while bytes.get(j) == Some(&b'#') {
        hashes += 1;
        j += 1;
    }
    if bytes.get(j) != Some(&b'"') {
        return None;
    }
    j += 1;
    while j < bytes.len() {
        if bytes[j] == b'"' {
            let mut k = j + 1;
            let mut seen = 0usize;
            while seen < hashes && bytes.get(k) == Some(&b'#') {
                seen += 1;
                k += 1;
            }
            if seen == hashes {
                return Some(k);
            }
        }
        j += 1;
    }
    Some(bytes.len())
}

/// Blank out comments and the bodies of string/char/raw-string literals,
/// preserving newlines and byte offsets.
///
/// Comment masking is what keeps this gate honest in both directions: the rule
/// is documented *in the sources it governs* (`shell.rs` and `primitives.rs`
/// name `Button::primary()` and `cx.theme()` in prose), and a comment can never
/// satisfy or trip it. Literal masking is what keeps a needle quoted in copy —
/// a tooltip, a JSON command name — out of the result.
///
/// Lossy decoding is safe: only ASCII bytes are ever blanked, so any multi-byte
/// character touched here lies inside a comment or literal that is already
/// discarded, and newlines (never blanked) keep every line number exact.
fn mask(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut out = bytes.to_vec();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'/' && bytes.get(i + 1) == Some(&b'/') {
            while i < bytes.len() && bytes[i] != b'\n' {
                out[i] = b' ';
                i += 1;
            }
        } else if c == b'/' && bytes.get(i + 1) == Some(&b'*') {
            let mut depth = 0usize;
            while i < bytes.len() {
                if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'*') {
                    depth += 1;
                    out[i] = b' ';
                    out[i + 1] = b' ';
                    i += 2;
                } else if bytes[i] == b'*' && bytes.get(i + 1) == Some(&b'/') {
                    depth -= 1;
                    out[i] = b' ';
                    out[i + 1] = b' ';
                    i += 2;
                    if depth == 0 {
                        break;
                    }
                } else {
                    if bytes[i] != b'\n' {
                        out[i] = b' ';
                    }
                    i += 1;
                }
            }
        } else if c == b'r' && matches!(bytes.get(i + 1), Some(b'"') | Some(b'#')) {
            match raw_string_end(bytes, i) {
                Some(end) => {
                    for byte in &mut out[i..end] {
                        if *byte != b'\n' {
                            *byte = b' ';
                        }
                    }
                    i = end;
                }
                None => i += 1,
            }
        } else if c == b'"' {
            i += 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'\\' => {
                        if bytes.get(i + 1) == Some(&b'\n') {
                            // A backslash-newline continuation keeps the string
                            // open on the next line; stay inside it.
                            i += 2;
                        } else {
                            out[i] = b' ';
                            if i + 1 < bytes.len() {
                                out[i + 1] = b' ';
                                i += 2;
                            } else {
                                i += 1;
                            }
                        }
                    }
                    b'"' => {
                        i += 1;
                        break;
                    }
                    b'\n' => break,
                    _ => {
                        out[i] = b' ';
                        i += 1;
                    }
                }
            }
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
    String::from_utf8_lossy(&out).into_owned()
}

/// Every banned needle is gone from the layer, except the reviewed exemptions.
///
/// A failure prints `apps/gpui-ui/src/<file>:<line>: \`<needle>\` in \`<the line>\``
/// so the fix is obvious: rebuild that control through `primitives` (an
/// icon-only control with a transparent resting surface, `scene::CONTROL_RADIUS`
/// and `scene::ICON`/`ICON_ACTIVE`), or — for a destructive action — colour a
/// token like `ui_tokens::stage::DANGER_TEXT`.
#[test]
fn overlay_layer_has_no_theme_derived_controls() {
    let roots = scan_roots();
    // (display path from the repo root, needle, line, raw line)
    let mut hits: Vec<(String, &'static str, usize, String)> = Vec::new();
    let mut scanned = 0usize;
    for (src, prefix) in &roots {
        let mut files = Vec::new();
        collect_rust(src, &mut files);
        files.sort();
        assert!(
            !files.is_empty(),
            "the gate must actually read `{prefix}`; no Rust source under {}",
            src.display()
        );
        scanned += files.len();
        for path in &files {
            let relative = format!(
                "{prefix}{}",
                path.strip_prefix(src)
                    .unwrap_or(path)
                    .to_string_lossy()
                    .replace('\\', "/")
            );
            let source = fs::read_to_string(path)
                .unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
            let code = mask(&source);
            let raw: Vec<&str> = source.lines().collect();
            for (index, line) in code.lines().enumerate() {
                for needle in BANNED {
                    if line.contains(needle) {
                        hits.push((
                            relative.clone(),
                            needle,
                            index + 1,
                            raw.get(index).copied().unwrap_or_default().trim().to_owned(),
                        ));
                    }
                }
            }
        }
    }
    assert!(
        scanned >= 10,
        "the gate must actually read the layer; it read {scanned} file(s) across {} root(s)",
        roots.len()
    );

    let mut failures = Vec::new();
    for (file, needle, line, text) in &hits {
        if !ALLOWED
            .iter()
            .any(|allowance| allowance.file == file && allowance.needle == *needle)
        {
            failures.push(format!("{file}:{line}: `{needle}` in `{text}`"));
        }
    }
    for allowance in ALLOWED {
        let count = hits
            .iter()
            .filter(|(file, needle, _, _)| {
                file == allowance.file && *needle == allowance.needle
            })
            .count();
        let file = allowance.file;
        let needle = allowance.needle;
        if count == 0 {
            failures.push(format!(
                "stale exemption: {file} no longer uses `{needle}`; delete the entry \
                 (its recorded reason was: {})",
                allowance.reason
            ));
        } else if count > allowance.max {
            failures.push(format!(
                "{file}: {count} × `{needle}` exceeds the {} recorded — a new theme-derived \
                 control has no exemption: {}",
                allowance.max, allowance.reason
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "the overlay layer must not take a control's chrome from `cx.theme()`; every control is \
         built from `primitives` over the fixed `ui_tokens::scene` palette. Offending \
         sites:\n{}",
        failures.join("\n")
    );
}

/// The scan must read code, not prose: the rule is documented in the very files
/// it governs, and a needle quoted in a string is not a control either. If this
/// fails, the gate above is either reporting comments or blind to real calls.
#[test]
fn the_gate_reads_code_not_comments_or_copy() {
    assert!(!mask("// Button::primary() turns a control white\n").contains(".primary()"));
    assert!(!mask("/* cx.theme() in a block comment */\n").contains("cx.theme()"));
    assert!(!mask("let label = \".danger()\";\n").contains(".danger()"));
    assert!(!mask("let svg = r#\"<path fill=\".primary()\"/\"#;\n").contains(".primary()"));
    assert!(mask("Button::new(\"x\").primary()\n").contains(".primary()"));
    assert!(
        mask("let url = \"https://example.test/a//b\";\nButton::new(\"x\").custom(v)\n")
            .contains(".custom("),
        "a URL inside a string must not swallow the rest of the line"
    );
    assert!(mask("fn f<'a>(x: &'a str) -> char { '\"' }\n").contains("'a str"));
}
