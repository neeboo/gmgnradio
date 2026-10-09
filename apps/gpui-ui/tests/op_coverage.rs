//! 机械门禁：`apps/gpui-ui/src/**` 里每个 `"op": "…"` 字面量都必须能在真实宿主
//! 源码里找到同名处理串，并且**产品宿主链**里也要有处理者（或在一份显式登记表
//! 里说明为什么不需要）。
//!
//! 放在 `apps/gpui-ui`（而不是 `apps/gpui-app`）的理由：被扫的字面量全部位于本
//! crate 的 `src/**`，这条门禁追的是这一层的出站命令面；`apps/gpui-ui` 的
//! `cargo test` 是 op 改动的最小回归入口，且本测试只读文件系统，不需要
//! `ui_shots` 那种 GPUI 主线程渲染 harness。
//!
//! ## 口径（2026-10-08 收紧）
//!
//! 旧口径只要求三棵宿主树里任意一处出现同名串，于是「Unity 宿主处理了，但
//! GPUI 产品宿主没有」这一类会漏过去——`space.library.load` 正是这样在生产模式
//! 里可见却必然失败。现在分成两条：
//!
//! 1. **存在处理者**：三棵真实宿主树的 `.swift` / `.rs` / `.cs` 文本里出现同名
//!    串即通过（`apps/macos/**`、`services/**`、`apps/unity-player/Assets/**`）。
//! 2. **产品模式可达**：每个 op 还必须出现在**产品宿主链**
//!    （`apps/macos/ProductHost/**` + `apps/macos/Sources/**`，即
//!    `ProductHost.settingsCommand` 及其委派的运行时）里；只有 Unity 宿主处理的
//!    op 必须逐条登记在 [`UNITY_HOST_ONLY_OPS`]，并写明「Unity 侧谁处理」与
//!    「产品模式下的处置」。登记表是**精确匹配**的：新增一个只有 Unity 处理的
//!    op 会让这条断言失败，逼一次显式决定，而不是静默放行。
//!
//! ## 2026-10-09 补两个反向缺陷
//!
//! 上面两条口径没防住两件事，本次补上：
//!
//! 1. **测试面不是命令面**：旧实现把 `apps/gpui-ui/src/**` 整份文件丢给
//!    [`op_literals`]，`#[cfg(test)] mod … { … }` 里为夹具写的 `json!({"op": …})`
//!    被算成「UI 会发」。`space.marble.{generate,resume,import,cancel}` 四条正是
//!    这样混进来的：它们的「发出点」全在 `settings.rs` 的测试模块里
//!    （`marble_commands_require_runtime_and_preserve_paid_receipts`），生产代码
//!    一条都没有。现在按括号配对剥掉测试模块**本体**（[`production_source`]，与
//!    `interface_parity.rs`、`services/gmgn-taskd/src/contract.rs::without_test_modules`
//!    同口径），只扫生产代码。
//! 2. **子串不是 token**：旧实现用 `haystack.contains(op)` 判定「宿主里有没有这个
//!    处理串」，于是 `video.stop` 被 `"stage.video.stop"` 里的子串命中——8 条
//!    `video.*`（`bind`/`brightness`/`mode`/`recoverStop`/`remove`/`select`/`stop`/
//!    `unbind`）因此被误判成「产品链可达」，而产品宿主里根本没有它们的处理者。
//!    现在两边都按**字符串字面量精确相等**匹配（[`string_literals`]：`"op"` 字面量、
//!    `case "…"`、数组元素都落在同一集合里），`"stage.video.stop"` 不再等于
//!    `video.stop`。暴露出来的 8 条按实情登记进 [`UNITY_HOST_ONLY_OPS`]，不放宽。
//!
//! 失败时逐条打印缺失的 op 及其出处（文件:行）。构建产物目录
//! （`Build.noindex`、`target`、`.build`、`DerivedData`、`node_modules`）跳过：
//! 门禁要盯的是源码，二进制/中间产物不是处理者（构建缓存里仅有的 7 个
//! `resource_bundle_accessor.swift` 是 Xcode 生成的 stub，不含任何 op 处理）。
//!
//! 覆盖边界：只认 `"op": "字面量"`。运行时拼接的 op（`"op": op`、
//! `format!("stage.props.{action}")`、`"op": if … { "video.play" } else { … }`）
//! 不在此口径内——它们的分支字面量在别处以 `"op": "…"` 形式出现，
//! 或属于 Unity 宿主（`apps/macos/UnityHost/**`）的独立命令面。

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

/// 宿主侧处理串所在的树（相对仓库根）。
const HANDLER_ROOTS: [&str; 3] = ["apps/macos", "services", "apps/unity-player/Assets"];
/// 产品宿主链：`ProductHost.settingsCommand` 及其委派的运行时。
const PRODUCT_HOST_ROOTS: [&str; 2] = ["apps/macos/ProductHost", "apps/macos/Sources"];
/// Unity 宿主：只有这里的处理者不算产品模式可用。
const UNITY_HOST_ROOTS: [&str; 2] = ["apps/macos/UnityHost", "apps/unity-player/Assets"];
/// 视作宿主源码的扩展名。
const HANDLER_EXTS: [&str; 3] = ["swift", "rs", "cs"];
/// 构建产物目录名：不是源码，跳过。
const PRUNED_DIRS: [&str; 5] = [
    "Build.noindex",
    ".build",
    "target",
    "DerivedData",
    "node_modules",
];

/// 只由 Unity 宿主处理、产品宿主链没有处理者的 op。
///
/// 每一项的格式是 `(op, "Unity 侧处理者 → 产品模式下的处置")`。这张表必须与
/// 实际扫描出的「非产品链 op」**完全相等**：少一条＝有 op 被静默放行，多一条＝
/// 登记已经过期（产品链接上了，或 UI 不再发出它）。
const UNITY_HOST_ONLY_OPS: &[(&str, &str)] = &[
    (
        "app.language",
        "UnityProductSettings.swift:119 → 产品快照（ProductHost/ProductSettingsParity.swift:60-133）没有 \
         `locale`，settings.rs 的语言菜单因此 `.disabled(true)`，产品模式发不出这个 op",
    ),
    (
        "generation.check",
        "UnityGenerationConfigurationBridge.swift:40 → settings.rs::wish_machine_section 只在 \
         `unity_external` 分支里渲染；产品分支用的是产品宿主已实现的 `space.prop.*`",
    ),
    (
        "generation.save",
        "UnityGenerationConfigurationBridge.swift:40 → 同 generation.check",
    ),
    (
        "presence.position",
        "UnityCharacterPositionBridge.swift:73 → settings.rs::character_position_form 只在 \
         `unity_external && section == \"角色管理\"` 时渲染",
    ),
    (
        "presence.position.reset",
        "UnityCharacterPositionBridge.swift:73 → 同 presence.position",
    ),
    (
        "shortcuts.capture",
        "UnityShortcutSettingsBridge.swift:44 → 产品模式**不再发出**：settings.rs::AgentSettingsPane::render \
         的按键转发带 `!this.unity_external` 门（settings.rs:4359-4390），只有独立进程的 Unity 设置窗 \
         （apps/gpui-app/src/bin/gmgn-unity-settings.rs:62 才 set_unity_external(true)）会转发 capture。\
         产品模式的录制由 `shortcuts.record` 触发的进程内 `NSEvent` 本地监视器完成 \
         （ProductHost/ProductSettingsParity.swift:324-354），实测见 docs/plans/2026-10-04-gpui-ui-parity.md:360",
    ),
    (
        "space.library.load",
        "UnitySpaceLibraryBridge.swift:104 → 产品模式**不再渲染**：settings.rs::space_library_available \
         要求快照里有 `spaceLibrary`，产品快照没有（本次收口）",
    ),
    (
        "space.library.select",
        "UnitySpaceLibraryBridge.swift:105 → 同 space.library.load（世界行与刷新按钮同一 section）",
    ),
    (
        "video.bind",
        "UnityScreenVideoBridge.swift:311 → settings.rs::video_page 只在 \
         `unity_external && section == \"视频\"` 渲染（settings.rs:4251 page_body）；产品模式的素材绑定走舞台面板的 \
         `stage.video.bind`（stage_panels.rs:344），由 ProductHost 处理",
    ),
    (
        "video.bound.dismiss",
        "UnityScreenVideoBridge.swift:319 → 同 video.bind（配对视频提示由 `stage.video.pending.dismiss` 承担）",
    ),
    (
        "video.bound.play",
        "UnityScreenVideoBridge.swift:319 → 同 video.bind（配对视频提示由 `stage.video.pending.play` 承担）",
    ),
    (
        "video.brightness",
        "UnityScreenVideoBridge.swift:303 → 滑杆订阅挂在 settings.rs:1188，但 `video_brightness` 只由 \
         video_page 渲染（settings.rs:2138），而 video_page 只在 `unity_external` 渲染（settings.rs:4251）；\
         产品模式的亮度走 `stage.video.brightness`（stage_panels.rs:446）",
    ),
    (
        "video.choose",
        "UnityScreenVideoBridge.swift:272 → 同 video.bind（产品模式的导入按钮发 `stage.video.import`，\
         stage_panels.rs:1433）",
    ),
    (
        "video.load",
        "UnityScreenVideoBridge.swift:249 → 同 video.bind；发出点在 settings.rs:1348 的 \
         `select_section`（带 `self.unity_external` 门）",
    ),
    (
        "video.mode",
        "UnityScreenVideoBridge.swift:295 → 同 video.bind（产品模式的模式切换走 `stage.video.mode`，\
         stage_panels.rs:1459）",
    ),
    (
        "video.recoverStop",
        "UnityScreenVideoBridge.swift:294 → 同 video.bind（产品模式走 `stage.video.recoverStop`，\
         stage_panels.rs:1506）",
    ),
    (
        "video.remove",
        "UnityScreenVideoBridge.swift:285 → 同 video.bind（产品模式走 `stage.video.remove`，\
         stage_panels.rs:349）",
    ),
    (
        "video.select",
        "UnityScreenVideoBridge.swift:282 → 同 video.bind（产品模式在舞台面板里选素材）",
    ),
    (
        "video.stop",
        "UnityScreenVideoBridge.swift:293 → 同 video.bind（产品模式走 `stage.video.stop`，\
         stage_panels.rs:1481）",
    ),
    (
        "video.unbind",
        "UnityScreenVideoBridge.swift:315 → 同 video.bind（产品模式走 `stage.video.unbind`，\
         stage_panels.rs:342）",
    ),
];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("apps/gpui-ui 的上一级是仓库根")
        .to_path_buf()
}

fn collect_files(dir: &Path, ext: &str, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if PRUNED_DIRS.contains(&name) {
                continue;
            }
            collect_files(&path, ext, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some(ext) {
            out.push(path);
        }
    }
}

/// 一棵宿主树里全部 `.swift`/`.rs`/`.cs` 源码的**字符串字面量集合**，并返回文件数。
///
/// 用字面量集合而不是 `text.contains(op)`：子串判定会把 `"stage.video.stop"` 里的
/// `video.stop` 当成处理者（2026-10-09 前 8 条 `video.*` 就是这样假阳性的）。
/// 处理者在三种宿主语言里都以字符串字面量出现（Swift `case "op":`、Rust
/// `"op" => …` / `op == "op"`、C# `case "op":`、`supportedCommands` 数组元素），
/// 精确相等就是正确的 token 模型。
fn host_literals(root: &Path, trees: &[&str]) -> (BTreeSet<String>, usize) {
    let mut literals = BTreeSet::new();
    let mut scanned = 0usize;
    for tree in trees {
        let dir = root.join(tree);
        assert!(dir.is_dir(), "缺少宿主源码树 {}", dir.display());
        for ext in HANDLER_EXTS {
            let mut files = Vec::new();
            collect_files(&dir, ext, &mut files);
            for file in files {
                if let Ok(text) = fs::read_to_string(&file) {
                    string_literals(&text, &mut literals);
                    scanned += 1;
                }
            }
        }
    }
    (literals, scanned)
}

/// 源码里所有 `"…"` 字面量的**内容**（不含引号）。
///
/// 跳过行注释、块注释与 Rust 的字符字面量/生命周期（`'"'` 不当作字符串开头，
/// 否则会一路吞到下一个真引号）。不做原始字符串/多行字符串的特殊处理：它们的
/// 内容会被拆成若干片段，而 op 都是单行普通字面量，拆开只会漏掉本来就不该匹配的
/// 形态，不会造出假阳性。
fn string_literals(source: &str, out: &mut BTreeSet<String>) {
    let bytes = source.as_bytes();
    let mut index = 0usize;
    while index < bytes.len() {
        match bytes[index] {
            b'/' if bytes.get(index + 1) == Some(&b'/') => {
                while index < bytes.len() && bytes[index] != b'\n' {
                    index += 1;
                }
            }
            b'/' if bytes.get(index + 1) == Some(&b'*') => {
                index += 2;
                while index + 1 < bytes.len() && !(bytes[index] == b'*' && bytes[index + 1] == b'/')
                {
                    index += 1;
                }
                index += 2;
            }
            b'\'' => {
                // `'\''`/`'\\'` 这类转义字符字面量占 4 字节，`'x'` 与 `'"'` 占 3，
                // 剩下的是生命周期（`'a`，2 字节）。
                index += if bytes.get(index + 1) == Some(&b'\\') {
                    4
                } else if bytes.get(index + 2) == Some(&b'\'') {
                    3
                } else {
                    2
                };
            }
            b'"' => {
                if let Some((value, next)) = string_at(source, index) {
                    if !value.is_empty() {
                        out.insert(value);
                    }
                    index = next;
                } else {
                    break;
                }
            }
            _ => index += 1,
        }
    }
}

/// 从 `at` 处的 `"` 起读一个字符串字面量，返回（内容，结束后的下标）。
///
/// 用字节下标切片而不是逐字符拼接：宿主源码含中文，逐 `byte as char` 拼接会把
/// UTF-8 拆坏（对本门禁无假阳性，但没必要）。
fn string_at(source: &str, at: usize) -> Option<(String, usize)> {
    let bytes = source.as_bytes();
    if *bytes.get(at)? != b'"' {
        return None;
    }
    let mut index = at + 1;
    while index < bytes.len() {
        match bytes[index] {
            b'\\' => index += 2,
            b'"' => return Some((source[at + 1..index].to_owned(), index + 1)),
            _ => index += 1,
        }
    }
    None
}

/// 剥掉每个 `#[cfg(test)] mod … { … }` 的**模块本体**（花括号配对），保留模块前后
/// 的生产代码。
///
/// 测试里写出的 `json!({"op": …})` 是夹具，不是 UI 的命令面。被剥掉的区间用**等量
/// 换行**覆盖而不是直接删掉：这样 source 的行号不变，`file:line` 仍然指向真实源码
/// 行。实现与 `interface_parity.rs::production_source`、
/// `services/gmgn-taskd/src/contract.rs::without_test_modules` 同口径。
fn production_source(src: &str) -> String {
    let mut out = src.to_owned();
    let mut from = 0usize;
    while let Some(at) = test_module_at(&out, from) {
        let Some(brace) = out[at..].find('{').map(|b| at + b) else { break };
        let Some(end) = balanced_brace_end(&out, brace) else { break };
        let stripped = "\n".repeat(out[at..=end].matches('\n').count());
        out.replace_range(at..=end, &stripped);
        from = at + stripped.len();
    }
    out
}

/// 下一个 `#[cfg(test)] mod …` 的起点。`#[cfg(test)]` 也可能挂在 `use`/`fn` 上，
/// 那些不是测试模块，跳过。
fn test_module_at(src: &str, from: usize) -> Option<usize> {
    let needle = "#[cfg(test)]";
    let mut at = from;
    while let Some(found) = src[at..].find(needle) {
        let start = at + found;
        if attributes_end_in_mod(&src[start + needle.len()..]) {
            return Some(start);
        }
        at = start + needle.len();
    }
    None
}

/// `#[cfg(test)]` 之后（中间可以隔着别的 `#[…]` 属性）是不是一个 `mod`。
fn attributes_end_in_mod(mut rest: &str) -> bool {
    loop {
        rest = rest.trim_start();
        let open = if rest.starts_with("#![") {
            2
        } else if rest.starts_with("#[") {
            1
        } else {
            break;
        };
        match find_close(rest, open, b'[', b']') {
            Some(close) => rest = &rest[close + 1..],
            None => return false,
        }
    }
    rest.starts_with("mod ")
        || rest
            .strip_prefix("pub(")
            .and_then(|r| r.split_once(')'))
            .map(|(_, r)| r.trim_start().starts_with("mod "))
            .unwrap_or(false)
        || rest.strip_prefix("pub ").map(|r| r.trim_start().starts_with("mod ")).unwrap_or(false)
}

/// 从 `src[open]` 的 `{` 起做花括号配对，跳过字符串、行注释与块注释。
fn balanced_brace_end(src: &str, open: usize) -> Option<usize> {
    let bytes = src.as_bytes();
    let mut depth = 0usize;
    let mut i = open;
    while i < bytes.len() {
        if bytes[i] == b'"' {
            i = string_at(src, i)?.1;
            continue;
        }
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'/') {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'*') {
            i += 2;
            while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                i += 1;
            }
            i += 2;
            continue;
        }
        if bytes[i] == b'{' {
            depth += 1;
        } else if bytes[i] == b'}' {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

fn find_close(src: &str, at: usize, open: u8, close: u8) -> Option<usize> {
    let bytes = src.as_bytes();
    let mut depth = 0usize;
    let mut i = at;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'"' {
            i = string_at(src, i)?.1;
            continue;
        }
        if c == b'/' && i + 1 < bytes.len() && bytes[i + 1] == b'/' {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if c == open {
            depth += 1;
        } else if c == close {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// 收集 `"op"` `:` `"…"` 形式的字面量及其 1 基行号。
///
/// 手写扫描而不是引正则：本 crate 没有 regex 依赖，而 JSON 宏里的字面量形态
/// 固定（`{"op":"x"}` 与 `{"op": "x"}` 都覆盖）。
fn op_literals(source: &str, out: &mut Vec<(String, usize)>) {
    let bytes = source.as_bytes();
    let mut index = 0usize;
    while index + 4 <= bytes.len() {
        if &bytes[index..index + 4] != b"\"op\"" {
            index += 1;
            continue;
        }
        let mut cursor = index + 4;
        while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= bytes.len() || bytes[cursor] != b':' {
            index += 1;
            continue;
        }
        cursor += 1;
        while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= bytes.len() || bytes[cursor] != b'"' {
            index += 1;
            continue;
        }
        let start = cursor + 1;
        let mut end = start;
        while end < bytes.len() && bytes[end] != b'"' {
            if bytes[end] == b'\\' {
                end += 1;
            }
            end += 1;
        }
        if end >= bytes.len() {
            break;
        }
        let value = &source[start..end];
        if !value.is_empty() {
            let line = source[..index].matches('\n').count() + 1;
            out.push((value.to_string(), line));
        }
        index = end + 1;
    }
}

/// 把两条修法自身钉住（作为 [`every_ui_op_literal_has_a_host_handler`] 的第 0 步，
/// 不另开一个测试，免得改动 `cargo test` 的测试计数）。
///
/// 退化回旧行为时这里先红：
/// * 剥测试模块如果「从 `#[cfg(test)]` 起把后面全丢」，夹在文件中间的测试模块会
///   吞掉它后面的生产 op；
/// * token 匹配如果退回 `contains`，`"stage.video.stop"` 又会被当成 `video.stop`
///   的处理者。
fn self_check_stripping_and_token_matching() {
    // 测试模块夹在生产代码中间（`settings.rs`/`stage_panels.rs` 就是这个形态）。
    let source = "\
fn before() { let _ = json!({\"op\":\"video.load\"}); }
#[cfg(test)]
mod tests {
    fn fixture() { let _ = json!({\"op\":\"space.marble.generate\"}); }
    fn braces() { let _ = \"}\"; }
}
fn after() { let _ = json!({\"op\":\"video.stop\"}); }
";
    let production = production_source(source);
    let mut ops = Vec::new();
    op_literals(&production, &mut ops);
    let names: Vec<&str> = ops.iter().map(|(op, _)| op.as_str()).collect();
    assert_eq!(
        names,
        ["video.load", "video.stop"],
        "剥掉测试模块，且它前后的生产 op 都还在（不能从 cfg(test) 起截断）"
    );
    assert_eq!(ops[0].1, 1);
    assert_eq!(ops[1].1, 7, "剥离用等量换行覆盖，file:line 仍指向真实源码行");

    // 子串 ≠ token。
    let mut literals = BTreeSet::new();
    string_literals("case \"stage.video.stop\": return true", &mut literals);
    assert!(literals.contains("stage.video.stop"));
    assert!(!literals.contains("video.stop"), "子串不得命中 token 匹配");

    // 注释与 Rust 字符字面量里的引号不产生 token（否则门禁会凭空多出处理者）。
    let mut literals = BTreeSet::new();
    string_literals("// \"video.stop\"\nlet q = '\"'; let s = \"video.play\";", &mut literals);
    assert!(!literals.contains("video.stop"), "注释里的字面量不算处理者");
    assert!(literals.contains("video.play"), "字符字面量 '\"' 不该吞掉后面的真字面量");
}

#[test]
fn every_ui_op_literal_has_a_host_handler() {
    // 0) 先钉住门禁自己的两条修法。
    self_check_stripping_and_token_matching();

    let root = repo_root();
    let src = root.join("apps/gpui-ui/src");
    assert!(src.is_dir(), "缺少被扫目录 {}", src.display());

    // 1) UI 侧：apps/gpui-ui/src/**/*.rs 的 op 字面量，**只算生产代码**。
    //
    // 同一份源码扫两遍：`raw` 用于打印「剥前/剥后」对照（测试模块里的夹具 op
    // 曾经被算成 UI 的命令面），`ops` 是喂给断言的剥后集合。
    let mut rust_files = Vec::new();
    collect_files(&src, "rs", &mut rust_files);
    rust_files.sort();
    assert!(!rust_files.is_empty(), "{} 下没有 Rust 源码", src.display());

    let mut ops: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut raw_ops: BTreeSet<String> = BTreeSet::new();
    for file in &rust_files {
        let source = fs::read_to_string(file)
            .unwrap_or_else(|error| panic!("读不到 {}: {error}", file.display()));
        let relative = file.strip_prefix(&root).unwrap_or(file).display().to_string();

        let mut raw = Vec::new();
        op_literals(&source, &mut raw);
        raw_ops.extend(raw.into_iter().map(|(op, _)| op));

        let mut found = Vec::new();
        op_literals(&production_source(&source), &mut found);
        for (op, line) in found {
            ops.entry(op).or_default().push(format!("{relative}:{line}"));
        }
    }
    assert!(!ops.is_empty(), "{} 下没有扫到任何 op 字面量", src.display());
    let dropped: Vec<&String> = raw_ops.iter().filter(|op| !ops.contains_key(*op)).collect();
    assert!(
        ops.keys().all(|op| raw_ops.contains(op)),
        "剥测试模块只应减少 op，不该造出新 op"
    );
    eprintln!(
        "op gate: 剥前 {} 个 op 字面量（含测试模块）→ 剥后 {} 个（生产代码），来自 {} 个 Rust 文件",
        raw_ops.len(),
        ops.len(),
        rust_files.len()
    );
    if !dropped.is_empty() {
        eprintln!("op gate: 被 #[cfg(test)] 剥掉的测试面 op（不参与断言）：{dropped:?}");
    }

    // 2) 宿主侧：三棵真实源码树的字符串字面量集合（token 精确匹配，非子串）。
    let (handlers, scanned) = host_literals(&root, &HANDLER_ROOTS);
    assert!(scanned > 0, "没有读到任何宿主源码文件");
    eprintln!("op gate: 扫描 {scanned} 个宿主源码文件 (.swift/.rs/.cs)");

    // 3) 逐个断言「存在处理者」；失败时打印缺哪个 op 以及它在 UI 里的出处。
    let missing: Vec<String> = ops
        .iter()
        .filter(|(op, _)| !handlers.contains(op.as_str()))
        .map(|(op, sites)| format!("  {op}  <- {}", sites.join(", ")))
        .collect();
    assert!(
        missing.is_empty(),
        "发现 {} 个 UI 发出但宿主没有任何处理串的 op：\n{}",
        missing.len(),
        missing.join("\n")
    );

    // 4) 产品模式可达：没有产品链处理者的 op 必须逐条登记。
    let (product, product_files) = host_literals(&root, &PRODUCT_HOST_ROOTS);
    assert!(product_files > 0, "没有读到任何产品宿主源码文件");
    eprintln!("op gate: 产品宿主链扫描 {product_files} 个文件");
    let (unity, _) = host_literals(&root, &UNITY_HOST_ROOTS);

    let registered: BTreeSet<&str> = UNITY_HOST_ONLY_OPS.iter().map(|(op, _)| *op).collect();
    assert_eq!(
        registered.len(),
        UNITY_HOST_ONLY_OPS.len(),
        "UNITY_HOST_ONLY_OPS 里有重复条目"
    );

    let unity_only: BTreeSet<String> = ops
        .keys()
        .filter(|op| !product.contains(op.as_str()))
        .cloned()
        .collect();

    let unregistered: Vec<&String> = unity_only
        .iter()
        .filter(|op| !registered.contains(op.as_str()))
        .collect();
    assert!(
        unregistered.is_empty(),
        "发现 {} 个「只有 Unity 宿主处理」的 op，却没有登记到 UNITY_HOST_ONLY_OPS；\
         产品模式下它们可见即必失败（本次收口就是这一类）：\n{}",
        unregistered.len(),
        unregistered
            .iter()
            .map(|op| format!("  {op}  <- {}", ops[*op].join(", ")))
            .collect::<Vec<_>>()
            .join("\n")
    );

    let stale: Vec<&str> = registered
        .iter()
        .copied()
        .filter(|op| !unity_only.contains(*op))
        .collect();
    assert!(
        stale.is_empty(),
        "UNITY_HOST_ONLY_OPS 里这些条目已经过期（产品链已处理，或 UI 不再发出）：{stale:?}"
    );

    for (op, reason) in UNITY_HOST_ONLY_OPS {
        assert!(
            unity.contains(*op),
            "{op} 登记为「只由 Unity 宿主处理」，但 Unity 树里找不到它：{reason}"
        );
    }
    eprintln!(
        "op gate: {} 个 op 由 Unity 宿主独有（已登记）",
        UNITY_HOST_ONLY_OPS.len()
    );
}

/// [`UNITY_HOST_ONLY_OPS`] 里 `shortcuts.capture` 的理由说「产品模式不再发出」，
/// 这条断言把那句话钉在代码上：转发 capture 的调用点必须落在
/// `!this.unity_external` 门之后。少了这道门，产品模式的记录面板又会在
/// 进程内监视器之外重复转发一个产品链没有处理者的 op。
#[test]
fn shortcut_capture_forwarding_stays_behind_the_unity_gate() {
    let path = repo_root().join("apps/gpui-ui/src/settings.rs");
    let source = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("读不到 {}: {error}", path.display()));
    let relative = path.strip_prefix(repo_root()).unwrap_or(&path).display().to_string();
    let call = source
        .find("shortcut_capture_command(&event.keystroke.key, flags)")
        .unwrap_or_else(|| panic!("{relative} 里找不到 capture 转发的调用点"));
    let listener = source[..call]
        .rfind(".on_key_down(")
        .unwrap_or_else(|| panic!("{relative} 的 capture 转发不在 on_key_down 监听器里"));
    let gate = "if !this.unity_external {";
    assert!(
        source[listener..call].contains(gate),
        "{relative}: capture 转发必须在 `{gate}` 之后——产品模式的按键录制由 ProductHost \
         进程内的 NSEvent 监视器完成（ProductSettingsParity.swift:324-354），面板只服务独立进程的 \
         Unity 设置窗"
    );
    let line = source[..listener].matches('\n').count() + 1;
    eprintln!("op gate: shortcuts.capture 转发固定在 {relative}:{line} 的 unity_external 门后");
}
