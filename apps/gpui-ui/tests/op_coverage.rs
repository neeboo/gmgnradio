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
        "space.marble.cancel",
        "UnityMarbleWorldBridge.swift:35 → settings.rs::marble_command 要求 `marbleWorking`，\
         产品快照无 `spaceLibrary` ⇒ 控件不渲染",
    ),
    (
        "space.marble.generate",
        "UnityMarbleWorldBridge.swift:83 → 同 space.marble.cancel（还要求 `generationSupported` 与预设）",
    ),
    (
        "space.marble.import",
        "UnityMarbleWorldBridge.swift:35 → 同 space.marble.cancel（按钮 `.disabled`）",
    ),
    (
        "space.marble.resume",
        "UnityMarbleWorldBridge.swift:35 → 同 space.marble.cancel（只在有 `marbleOperationID` 时才渲染）",
    ),
    (
        "video.bound.dismiss",
        "UnityScreenVideoBridge.swift:12 → settings.rs::video_page 只在 \
         `unity_external && section == \"视频\"` 渲染",
    ),
    (
        "video.bound.play",
        "UnityScreenVideoBridge.swift:12 → 同 video.bound.dismiss",
    ),
    (
        "video.choose",
        "UnityScreenVideoBridge.swift:12 → 同 video.bound.dismiss",
    ),
    (
        "video.load",
        "UnityScreenVideoBridge.swift:240 → 同 video.bound.dismiss（产品模式改用舞台面板的 \
         `stage.video.*`，由 ProductHost 处理）",
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

/// 一棵宿主树里全部 `.swift`/`.rs`/`.cs` 源码拼起来，并返回文件数。
fn host_haystack(root: &Path, trees: &[&str]) -> (String, usize) {
    let mut haystack = String::new();
    let mut scanned = 0usize;
    for tree in trees {
        let dir = root.join(tree);
        assert!(dir.is_dir(), "缺少宿主源码树 {}", dir.display());
        for ext in HANDLER_EXTS {
            let mut files = Vec::new();
            collect_files(&dir, ext, &mut files);
            for file in files {
                if let Ok(text) = fs::read_to_string(&file) {
                    haystack.push_str(&text);
                    haystack.push('\n');
                    scanned += 1;
                }
            }
        }
    }
    (haystack, scanned)
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

#[test]
fn every_ui_op_literal_has_a_host_handler() {
    let root = repo_root();
    let src = root.join("apps/gpui-ui/src");
    assert!(src.is_dir(), "缺少被扫目录 {}", src.display());

    // 1) UI 侧：apps/gpui-ui/src/**/*.rs 的 op 字面量。
    let mut rust_files = Vec::new();
    collect_files(&src, "rs", &mut rust_files);
    rust_files.sort();
    assert!(!rust_files.is_empty(), "{} 下没有 Rust 源码", src.display());

    let mut ops: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for file in &rust_files {
        let source = fs::read_to_string(file)
            .unwrap_or_else(|error| panic!("读不到 {}: {error}", file.display()));
        let mut found = Vec::new();
        op_literals(&source, &mut found);
        let relative = file.strip_prefix(&root).unwrap_or(file).display().to_string();
        for (op, line) in found {
            ops.entry(op).or_default().push(format!("{relative}:{line}"));
        }
    }
    assert!(!ops.is_empty(), "{} 下没有扫到任何 op 字面量", src.display());
    eprintln!(
        "op gate: {} 个 op 字面量, 来自 {} 个 Rust 文件",
        ops.len(),
        rust_files.len()
    );

    // 2) 宿主侧：三棵真实源码树的文本处理串。
    let (haystack, scanned) = host_haystack(&root, &HANDLER_ROOTS);
    assert!(scanned > 0, "没有读到任何宿主源码文件");
    eprintln!("op gate: 扫描 {scanned} 个宿主源码文件 (.swift/.rs/.cs)");

    // 3) 逐个断言「存在处理者」；失败时打印缺哪个 op 以及它在 UI 里的出处。
    let missing: Vec<String> = ops
        .iter()
        .filter(|(op, _)| !haystack.contains(op.as_str()))
        .map(|(op, sites)| format!("  {op}  <- {}", sites.join(", ")))
        .collect();
    assert!(
        missing.is_empty(),
        "发现 {} 个 UI 发出但宿主没有任何处理串的 op：\n{}",
        missing.len(),
        missing.join("\n")
    );

    // 4) 产品模式可达：没有产品链处理者的 op 必须逐条登记。
    let (product, product_files) = host_haystack(&root, &PRODUCT_HOST_ROOTS);
    assert!(product_files > 0, "没有读到任何产品宿主源码文件");
    eprintln!("op gate: 产品宿主链扫描 {product_files} 个文件");
    let (unity, _) = host_haystack(&root, &UNITY_HOST_ROOTS);

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
            unity.contains(op),
            "{op} 登记为「只由 Unity 宿主处理」，但 Unity 树里找不到它：{reason}"
        );
    }
    eprintln!(
        "op gate: {} 个 op 由 Unity 宿主独有（已登记，其中 space.library.* 已在产品模式停渲染）",
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
