//! 跨语言接口对齐门禁（2026-10-08）。
//!
//! `op_coverage.rs` 只比 op 名字符串；这条门禁往下走一层：比**字段**、**快照键**、
//! **Rust 方法名**和**工具 schema 形态**。
//!
//! 清单与结论见 `docs/plans/2026-10-08-ui-interface-parity.md`。本文件里的
//! [`OPS`] 表是那份清单的机器可读副本：每个 op 声明它从 UI 发出的字段、以及必须
//! 读到这些字段的宿主函数。断言在运行时**重新扫描真实源码**，所以表过期或源码
//! 改动都会红。
//!
//! 四条断言：
//! 1. [`op_field_sets_match_the_source_and_are_read`]：UI 的 op 集合与字段集合必须
//!    与 [`OPS`] 完全一致；每个发出的字段必须在声明的宿主处理者里出现
//!    `["字段"]` 读取（除非逐条登记在 [`UNREAD_FIELDS_OK`] 并写明理由）。
//! 2. [`required_fields_are_emitted_by_the_ui`]：宿主 `guard let x = value["f"] …
//!    else { return false }` 这类**必填**字段，UI 必须真的发。
//! 3. [`tool_schema_types_are_supported_by_the_authority`]：`apps/macos/**` 里
//!    `"type": [...]` 联合类型必须落在 `agent_tools.rs` 的 `schema_defect` 词表内。
//! 4. [`snapshot_root_keys_are_produced_by_the_host`]：UI 读的 ABI 根键必须在
//!    overlay 的快照投影白名单里。
//!
//! 口径：只认测试模块**之外**的源码，按括号配对剥掉 `#[cfg(test)] mod … { … }`
//! 本体。`apps/gpui-ui/src/**` 里大量 `json!` 字面量位于 `mod tests` 内
//! （`stage_panels.rs:358`、`props.rs:788`、`settings.rs:4460`…），它们不是 UI 能发出
//! 的 op。
//!
//! 注意**不能**写成"遇到第一个测试模块就把后面全丢"：`stage_panels.rs:358` 的
//! `video_menu_tests` 和 `stage_panels/props.rs:788` 的 `tests` 都夹在生产代码**中间**
//! （`stage_panels.rs` 之后还有 1400+ 行生产代码，`props.rs` 之后还有
//! `impl Render for ResidentPropEditorPane` 整块），截断会把它们后面的全部发出点
//! 一起丢掉。括号配对与 `services/gmgn-taskd/src/contract.rs` 的
//! `without_test_modules`、`tools/audit-ui-function-inventory.py` 同口径。

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

const PRUNED_DIRS: [&str; 7] = [
    "Build.noindex",
    ".build",
    "target",
    "DerivedData",
    "node_modules",
    "checkouts",
    "Tests",
];

/// 命令字典的接收者名。只有这些变量上的 `["x"]` 才算读命令字段；
/// `operations["prop"]` 这种字典下标不算。
const RECEIVERS: [&str; 14] = [
    "value", "command", "params", "p", "input", "fields", "arguments", "body", "payload", "obj",
    "json", "incoming", "envelope", "request",
];

struct Handler {
    file: &'static str,
    /// `case "op":` 所在的源文件；region = 该 case 臂的前导语句 + 臂体。
    ops: &'static [&'static str],
    /// 非空时改用整个函数体（委派目标：`if op == …` 形式，没有 `case`）。
    func_anchor: &'static str,
}

struct OpContract {
    op: &'static str,
    ui_fields: &'static [&'static str],
    /// 该 op 在宿主里被改写成另一个 op（字段原样带过去），其读取算在目标身上。
    rewrite_to: Option<&'static str>,
    handlers: &'static [Handler],
}

/// UI 发了、但当前没有任何宿主读取的字段。必须逐条登记理由。
///
/// 2026-10-08 收口后为空：`stage.video.unbind.id` 由
/// `UnityScreenVideoBridge.command` 校验（越过期的素材 id 不再解绑别的绑定），
/// `video.unbind` 的 UI 发出点不再带 `id`（只带它真正使用的 `trackID`）。
/// 新条目必须写明「哪个宿主函数读了它」之外的理由，否则应改源码而不是登记。
const UNREAD_FIELDS_OK: &[(&str, &str, &str)] = &[];

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("apps/gpui-ui 的上一级是仓库根")
        .to_path_buf()
}

fn read(root: &Path, rel: &str) -> String {
    let path = root.join(rel);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("读不到 {}: {e}", path.display()))
}

fn collect(dir: &Path, ext: &str, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if !PRUNED_DIRS.contains(&name) {
                collect(&path, ext, out);
            }
        } else if path.extension().and_then(|e| e.to_str()) == Some(ext) {
            out.push(path);
        }
    }
}

/// 剥掉每个 `#[cfg(test)] mod … { … }` 的**模块本体**（花括号配对），保留模块前后
/// 的生产代码。测试里写出的 op/字段不算 UI 的命令面，但生产代码**不因为包着它的
/// 测试模块而消失**。
///
/// 旧实现（`find` 到第一个 `#[cfg(test)] mod` 就 `return &src[..at]`）在
/// `stage_panels.rs:358` 的 `video_menu_tests`、`stage_panels/props.rs:788` 的
/// `tests` 处截断——这两个测试模块都在文件中间，所以它们之后的全部发出点从未被
/// 扫描过。
///
/// 被剥掉的区间用**等量换行**覆盖而不是直接删掉：这样 source 的行号不变，
/// `file:line` 仍然指向真实源码行（断言失败信息里报的就是它）。括号配对跳过字符串、
/// 行注释与块注释；换行本身不含 `#[cfg(test)]`，所以替换文本不会自我递归。
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

fn string_at(src: &str, at: usize) -> Option<(String, usize)> {
    let bytes = src.as_bytes();
    if *bytes.get(at)? != b'"' {
        return None;
    }
    let mut i = at + 1;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            b'"' => return Some((src[at + 1..i].to_owned(), i + 1)),
            _ => i += 1,
        }
    }
    None
}

/// 从 `from` 起找下一个字符串字面量。
fn next_string(src: &str, from: usize) -> Option<(String, usize)> {
    let at = src[from..].find('"')? + from;
    string_at(src, at)
}

fn skip_ws(src: &str, mut i: usize) -> usize {
    let bytes = src.as_bytes();
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }
    i
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

/// 一个 op 的发出点：文件、1 基行号、字段名 -> 值形态。
struct Emission {
    op: String,
    file: String,
    line: usize,
    fields: Vec<(String, String)>,
}

fn classify(value: &str) -> String {
    let v = value.trim();
    if v.starts_with('"') {
        return match string_at(v, 0) {
            Some((_, end)) if v[end..].trim().is_empty() => "string".to_owned(),
            _ => "expr".to_owned(),
        };
    }
    if v == "true" || v == "false" {
        return "bool".to_owned();
    }
    if v == "null" {
        return "null".to_owned();
    }
    if v.starts_with(|c: char| c == '-' || c.is_ascii_digit()) {
        return "number".to_owned();
    }
    "expr".to_owned()
}

/// 扫描 `json!({...})` 里的 op 与字段。
fn emissions(file: &str, src: &str, out: &mut Vec<Emission>) {
    let mut at = 0usize;
    while let Some(found) = src[at..].find("json!(") {
        let start = at + found + "json!".len();
        let Some(close) = find_close(src, start, b'(', b')') else { break };
        let body = src[start + 1..close].trim();
        at = close;
        if !body.starts_with('{') {
            continue;
        }
        let Some(obj_end) = find_close(body, 0, b'{', b'}') else { continue };
        let inner = &body[1..obj_end];
        let line = src[..start].matches('\n').count() + 1;
        let mut fields = Vec::new();
        let mut ops: Vec<String> = Vec::new();
        let mut i = 0usize;
        let ib = inner.as_bytes();
        let mut depth = 0i32;
        let mut piece_start = 0usize;
        let mut pieces: Vec<&str> = Vec::new();
        while i < ib.len() {
            match ib[i] {
                b'"' => {
                    i = string_at(inner, i).map(|(_, e)| e).unwrap_or(ib.len());
                    continue;
                }
                b'{' | b'(' | b'[' => depth += 1,
                b'}' | b')' | b']' => depth -= 1,
                b',' if depth == 0 => {
                    pieces.push(&inner[piece_start..i]);
                    piece_start = i + 1;
                }
                _ => {}
            }
            i += 1;
        }
        pieces.push(&inner[piece_start..]);
        for piece in pieces {
            let piece = piece.trim();
            let Some((key, _)) = string_at(piece, 0) else { continue };
            let after = skip_ws(piece, key.len() + 2);
            if piece.as_bytes().get(after) != Some(&b':') {
                continue;
            }
            let value = piece[after + 1..].trim();
            if key == "op" {
                if let Some((literal, end)) = string_at(value, 0) {
                    if value[end..].trim().is_empty() {
                        ops.push(literal);
                    }
                }
                // `if cond { "a" } else { "b" }` 形态
                for arm in value.split("else") {
                    if let Some(brace) = arm.find('{') {
                        let t = arm[brace + 1..].trim_start();
                        if let Some((literal, end)) = string_at(t, 0) {
                            if t[end..].trim_start().starts_with('}') {
                                ops.push(literal);
                            }
                        }
                    }
                }
                continue;
            }
            fields.push((key, classify(value)));
        }
        for op in ops {
            out.push(Emission {
                op,
                file: file.to_owned(),
                line,
                fields: fields.clone(),
            });
        }
    }
}

fn case_regions(src: &str) -> Vec<(Vec<String>, usize, String)> {
    let lines: Vec<&str> = src.split('\n').collect();
    let indent = |l: &str| l.len() - l.trim_start().len();
    let is_arm = |l: &str| {
        let t = l.trim_start();
        t.starts_with("case ") || t.starts_with("default") || t.starts_with("@unknown")
    };
    let mut out = Vec::new();
    for (i, line) in lines.iter().enumerate() {
        let t = line.trim_start();
        if !t.starts_with("case ") {
            continue;
        }
        // `case "a", "b": …`：冒号前只允许 case/空白/字符串/逗号/竖线。
        let rest = &t["case ".len()..];
        let mut ops = Vec::new();
        let mut cursor = 0usize;
        let mut colon = None;
        loop {
            let tail = &rest[cursor..];
            let ws = tail.len() - tail.trim_start().len();
            cursor += ws;
            match rest.as_bytes().get(cursor) {
                Some(b'"') => {
                    let Some((literal, end)) = string_at(rest, cursor) else { break };
                    ops.push(literal);
                    cursor = end;
                }
                Some(b',') | Some(b'|') => cursor += 1,
                Some(b':') => {
                    colon = Some(cursor);
                    break;
                }
                _ => break,
            }
        }
        let Some(_colon) = colon else { continue };
        if ops.is_empty() {
            continue;
        }
        let ind = indent(line);
        let mut j = i + 1;
        while j < lines.len() {
            if lines[j].trim().is_empty() {
                j += 1;
                continue;
            }
            let cur = indent(lines[j]);
            if cur < ind || (cur == ind && is_arm(lines[j])) {
                break;
            }
            j += 1;
        }
        // 前导：向外找开启行（缩进更小），取其后的**开头连续非 case 语句**。
        let mut opener = None;
        let mut k = i;
        while k > 0 {
            k -= 1;
            if !lines[k].trim().is_empty() && indent(lines[k]) < ind {
                opener = Some(k);
                break;
            }
        }
        let mut head_lines: Vec<&str> = Vec::new();
        if let Some(opener) = opener {
            for l in &lines[opener + 1..i] {
                if is_arm(l) || l.trim_start().starts_with("switch ") {
                    break;
                }
                head_lines.push(l);
            }
        }
        let mut region = head_lines.join("\n");
        region.push('\n');
        // 同行 case 体（`case "x": foo()`）也要算进来。
        region.push_str(&line[line.find(':').map(|c| c + 1).unwrap_or(line.len())..]);
        region.push('\n');
        region.push_str(&lines[i + 1..j].join("\n"));
        let region = strip_foreign_op_ifs(&region, &ops);
        out.push((ops, i + 1, region));
    }
    out
}

/// 去掉 `if op == "别的 op" { … }` / `if op.hasPrefix("别的前缀") { … }` 块：
/// 它们是**别的** op 的早退分支，不该算进本 op 的必填字段。
fn strip_foreign_op_ifs(text: &str, keep: &[String]) -> String {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut out: Vec<&str> = Vec::new();
    let mut i = 0usize;
    while i < lines.len() {
        if !lines[i].trim_start().starts_with("if ") {
            out.push(lines[i]);
            i += 1;
            continue;
        }
        let mut cond = String::new();
        let mut j = i;
        while j < lines.len() && !lines[j].contains('{') {
            cond.push_str(lines[j]);
            j += 1;
        }
        if j >= lines.len() {
            out.extend_from_slice(&lines[i..]);
            break;
        }
        if let Some((before, _)) = lines[j].split_once('{') {
            cond.push_str(before);
        }
        let eqs = quoted_after(&cond, "op == ");
        let pfx = quoted_after(&cond, "op.hasPrefix(");
        let foreign = (!eqs.is_empty() && !eqs.iter().any(|o| keep.contains(o)))
            || (!pfx.is_empty() && !keep.iter().any(|k| pfx.iter().any(|p| k.starts_with(p.as_str()))));
        if !foreign {
            out.push(lines[i]);
            i += 1;
            continue;
        }
        let rest = lines[i..].join("\n");
        let Some(brace) = rest.find('{') else { break };
        let mut depth = 0i32;
        let rb = rest.as_bytes();
        let mut p = brace;
        while p < rb.len() {
            match rb[p] {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                _ => {}
            }
            p += 1;
        }
        let consumed = rest[..=p.min(rest.len() - 1)].matches('\n').count();
        i += consumed.max(1);
    }
    out.join("\n")
}

fn quoted_after(text: &str, needle: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut from = 0usize;
    while let Some(at) = text[from..].find(needle) {
        let at = from + at + needle.len();
        if let Some((literal, end)) = string_at(text, at) {
            out.push(literal);
            from = end;
        } else {
            from = at;
        }
    }
    out
}

fn receiver_subscripts(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for (i, _) in text.match_indices('[') {
        // 往前取标识符
        let bytes = text.as_bytes();
        let mut s = i;
        while s > 0 && (bytes[s - 1].is_ascii_alphanumeric() || bytes[s - 1] == b'_') {
            s -= 1;
        }
        let recv = &text[s..i];
        if !RECEIVERS.contains(&recv) {
            continue;
        }
        let after = skip_ws(text, i + 1);
        if let Some((key, _)) = string_at(text, after) {
            let close = skip_ws(text, after + key.len() + 2);
            if text.as_bytes().get(close) == Some(&b']') {
                out.push(key);
            }
        }
    }
    out
}

/// `guard let x = value["f"] … else { … return false/nil … }` 里的 `f`。
/// `value["f"] == nil || …` / `!= nil && …` 表示「缺省也合法」，不算必填。
fn guard_required(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut from = 0usize;
    while let Some(at) = text[from..].find("guard ") {
        let at = from + at + "guard ".len();
        let Some(else_at) = text[at..].find("else") else { break };
        let cond = &text[at..at + else_at];
        let brace_rel = text[at + else_at..].find('{');
        from = at + else_at + 1;
        let Some(brace_rel) = brace_rel else { continue };
        let brace = at + else_at + brace_rel;
        let mut depth = 0i32;
        let bytes = text.as_bytes();
        let mut p = brace;
        while p < bytes.len() {
            match bytes[p] {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                _ => {}
            }
            p += 1;
        }
        let body = &text[brace + 1..p.min(text.len())];
        if !body.contains("return false") && !body.contains("return nil") {
            continue;
        }
        for field in receiver_subscripts(cond) {
            let optional = cond.contains(&format!("\"{field}\"] == nil"))
                || cond.contains(&format!("\"{field}\"] != nil"));
            if !optional {
                out.push(field);
            }
        }
    }
    out
}

fn handler_regions(root: &Path, h: &Handler) -> Vec<(String, usize, String)> {
    let src = read(root, h.file);
    if !h.func_anchor.is_empty() {
        let Some(at) = src.find(h.func_anchor) else {
            panic!("{} 里找不到处理者锚点 {:?}", h.file, h.func_anchor);
        };
        let Some(brace) = src[at..].find('{') else {
            panic!("{} 的处理者锚点后没有函数体", h.file)
        };
        let open = at + brace;
        let Some(close) = find_close(&src, open, b'{', b'}') else {
            panic!("{} 的处理者函数体不闭合", h.file)
        };
        let line = src[..at].matches('\n').count() + 1;
        return vec![(h.file.to_owned(), line, src[at..=close].to_owned())];
    }
    let production = production_source(&src);
    let mut out: Vec<(String, usize, String)> = case_regions(&production)
        .into_iter()
        .filter(|(ops, _, _)| ops.iter().any(|o| h.ops.contains(&o.as_str())))
        .map(|(_, line, region)| (h.file.to_owned(), line, region))
        .collect();
    // `case "x":` 找不到时才退到 `if op == "x" { … }`：`ProductHost.settingsCommand`
    // 用「op 前缀分派 + if 早退」而不是 `case`，不认这种分支就看不到处理者。
    // 只在为空时回退，已有 `case` 臂的 op 行为不变。
    if out.is_empty() {
        out.extend(
            if_regions(&production, h.ops)
                .into_iter()
                .map(|(line, region)| (h.file.to_owned(), line, region)),
        );
    }
    out
}

/// `if op == "…" { … }` / `if op.hasPrefix("…") { … }` 形式的分支区域。
/// 条件可以跨行，块用花括号配对切出。`keep` 全是空字符串的 handler 不产出区域。
///
/// 外层宽前缀 `if op.hasPrefix("stage.") { … }` 会把里面**每个** op 的实现
/// （包括它们各自 `if op == "别的 op"` 里的 guard）都吞进来，所以同一分支内
/// 若还有更精确的匹配，只保留**最内层**的那个：这与 [`strip_foreign_op_ifs`]
/// 「别的 op 的早退不算本 op 的必填字段」是同一条理由。
fn if_regions(src: &str, keep: &[&str]) -> Vec<(usize, String)> {
    if keep.is_empty() {
        return Vec::new();
    }
    let lines: Vec<&str> = src.split('\n').collect();
    // 候选：(起始行 1 基, 结束行 1 基, 区域原文)。
    let mut candidates: Vec<(usize, usize, String)> = Vec::new();
    let mut i = 0usize;
    while i < lines.len() {
        if !lines[i].trim_start().starts_with("if ") {
            i += 1;
            continue;
        }
        let mut cond = String::new();
        let mut j = i;
        while j < lines.len() && !lines[j].contains('{') {
            cond.push_str(lines[j]);
            j += 1;
        }
        if j >= lines.len() {
            break;
        }
        if let Some((before, _)) = lines[j].split_once('{') {
            cond.push_str(before);
        }
        let eqs = quoted_after(&cond, "op == ");
        let pfx = quoted_after(&cond, "op.hasPrefix(");
        let matches = eqs.iter().any(|o| keep.contains(&o.as_str()))
            || pfx.iter().any(|p| keep.iter().any(|k| k.starts_with(p.as_str())));
        if matches {
            let rest = lines[i..].join("\n");
            let Some(brace) = rest.find('{') else { break };
            let Some(end) = balanced_brace_end(&rest, brace) else { break };
            let consumed = rest[..=end].matches('\n').count();
            candidates.push((i + 1, i + 2 + consumed, rest[..=end].to_owned()));
        }
        i += 1;
    }
    let mut keep_candidate = vec![true; candidates.len()];
    for a in 0..candidates.len() {
        for b in 0..candidates.len() {
            if a != b
                && candidates[b].0 > candidates[a].0
                && candidates[b].1 <= candidates[a].1
            {
                keep_candidate[a] = false;
                break;
            }
        }
    }
    candidates
        .into_iter()
        .enumerate()
        .filter(|(index, _)| keep_candidate[*index])
        .map(|(_, (line, _, region))| (line, region))
        .collect()
}
/// 每个 op 的字段面与必须读到它们的宿主处理者。清单见
/// `docs/plans/2026-10-08-ui-interface-parity.md`。
const OPS: &[OpContract] = &[
    OpContract {
        op: "agent.login",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["agent.login"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["agent.login"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "agent.logout",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["agent.logout"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["agent.logout"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "agent.save",
        ui_fields: &["hostPrompt", "planningModel", "residentPersona"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["agent.save"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["agent.save"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityProductSettings.swift", ops: &["agent.save"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "app.language",
        ui_fields: &["locale"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityProductSettings.swift", ops: &["app.language"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "generation.check",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift", ops: &["generation.check"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["generation.check"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "generation.save",
        ui_fields: &["endpoint", "token"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift", ops: &["generation.save"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["generation.save"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "inbox.open",
        ui_fields: &["expectedEventID", "id", "scope"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["inbox.open"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "music.connect",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["music.connect"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["music.connect"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "music.disconnect",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["music.disconnect"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["music.disconnect"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "music.sync",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["music.sync"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["music.sync"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.activate",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.activate"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.activate"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.catalog",
        ui_fields: &["url"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.catalog"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.catalog"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.import",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.import"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.import"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.import.link",
        ui_fields: &["url"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.import.link"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.import.link"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.load",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.load"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.load"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.motion",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.motion"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["presence.motion"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.motion"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.motion.import",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.motion.import"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.motion.import"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.motion.install",
        ui_fields: &["catalogIdentity"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.motion.install"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.motion.install"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.motion.remove",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.motion.remove"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.motion.remove"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.orb.color",
        ui_fields: &["blue", "green", "red"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.orb.color"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.orb.color"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.orb.intensity",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.orb.intensity"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.orb.intensity"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "presence.position",
        ui_fields: &["expectedLayoutRevision", "expectedRevision", "position", "requestID", "worldID"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["presence.position"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityCharacterPositionBridge.swift", ops: &[], func_anchor: "func command(_ value: [String: Any]) -> Bool" },
        ],
    },
    OpContract {
        op: "presence.position.reset",
        ui_fields: &["expectedLayoutRevision", "expectedRevision", "requestID", "worldID"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["presence.position.reset"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityCharacterPositionBridge.swift", ops: &[], func_anchor: "func command(_ value: [String: Any]) -> Bool" },
        ],
    },
    OpContract {
        op: "presence.remove",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["presence.remove"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", ops: &["presence.remove"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "settings.load",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["settings.load"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["settings.load"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityProductSettings.swift", ops: &["settings.load"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "settings.open.presence",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            // 原版 `StageOverlayView` 的「管理角色与动作…」＝ `onManageAssets`。
            // `ProductHost.settingsCommand` 把它交给 `runtime.openPresenceSettings()`
            // （先把设置定位到角色页，再打开设置窗口）。
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["settings.open.presence"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "shortcuts.cancel",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["shortcuts.cancel"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityShortcutSettingsBridge.swift", ops: &["shortcuts.cancel"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "shortcuts.capture",
        ui_fields: &["keyCode", "keyLabel", "modifiers"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityShortcutSettingsBridge.swift", ops: &["shortcuts.capture"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "shortcuts.global",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["shortcuts.global"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityShortcutSettingsBridge.swift", ops: &["shortcuts.global"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "shortcuts.media",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["shortcuts.media"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityShortcutSettingsBridge.swift", ops: &["shortcuts.media"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "shortcuts.record",
        ui_fields: &["id", "scope"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["shortcuts.record"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityShortcutSettingsBridge.swift", ops: &["shortcuts.record"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "shortcuts.reset",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["shortcuts.reset"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityShortcutSettingsBridge.swift", ops: &["shortcuts.reset"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "space.default",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["space.default"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["space.default"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnitySpaceLibraryBridge.swift", ops: &["space.default"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "space.key.clear",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["space.key.clear"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityProductSettings.swift", ops: &["space.key.clear"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "space.key.save",
        ui_fields: &["apiKey"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["space.key.save"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityProductSettings.swift", ops: &["space.key.save"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "space.library.load",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["space.library.load"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnitySpaceLibraryBridge.swift", ops: &["space.library.load"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "space.library.select",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["space.library.select"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnitySpaceLibraryBridge.swift", ops: &["space.library.select"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "space.prop.cancel",
        ui_fields: &["clearNotice"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["space.prop.cancel"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "space.prop.check",
        ui_fields: &["endpoint"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["space.prop.check"], func_anchor: "" },
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &[], func_anchor: "private func checkProps(_ value: [String: Any])" },
        ],
    },
    OpContract {
        op: "space.prop.save",
        ui_fields: &["apiKey", "endpoint"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &["space.prop.save"], func_anchor: "" },
            Handler { file: "apps/macos/ProductHost/ProductSettingsParity.swift", ops: &[], func_anchor: "private func saveProps(_ value: [String: Any]) -> Bool" },
        ],
    },
    OpContract {
        op: "speech.settings.cancel",
        ui_fields: &["cancelCapabilities", "clearVoices"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["speech.settings.cancel"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityProductSettings.swift", ops: &["speech.settings.cancel"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "speech.settings.load",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["speech.settings.load"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityProductSettings.swift", ops: &["speech.settings.load"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.activity.run",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.activity.run"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["stage.activity.run"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.activity.stop",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.activity.stop"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["stage.activity.stop"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.avatar.position",
        ui_fields: &["axis", "value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.avatar.position"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.avatar.reset",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.avatar.reset"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.camera.reset",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.camera.reset"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.motion.activate",
        ui_fields: &["id"],
        // `ProductHost.settingsCommand` 把这个 op 改写成 `presence.motion`，并把
        // 同一个字典原样交给设置链（字段一起过去），所以 `id` 的读取算在目标 op 上。
        rewrite_to: Some("presence.motion"),
        handlers: &[
            // 处理者是 `if op == "stage.motion.activate" { … }`，不是 `case` 臂。
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["stage.motion.activate"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.motion.refresh",
        ui_fields: &[],
        // 宿主**新建** `["op": "presence.load"]`，不携带任何字段，所以这里不是
        // `rewrite_to`：UI 侧没有字段需要过去，宿主也不要求它带字段。
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["stage.motion.refresh"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.player.particles",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.player.particles"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["stage.player.particles"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.program.back",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.program.back"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.program.load",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.program.load"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.program.more",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.program.more"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.program.play",
        ui_fields: &["slotIndex"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.program.play"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.program.replan",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.program.replan"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.program.video",
        ui_fields: &["trackID"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.program.video"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.close",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.close"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.delete",
        ui_fields: &["objectID"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.delete"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.filter",
        ui_fields: &["placedOnly"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.filter"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.fold",
        ui_fields: &["folded", "group"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.fold"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.hold",
        ui_fields: &["point"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.hold"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.load",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.load"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.nudge",
        ui_fields: &["y", "z"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.nudge"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.resize",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.resize"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.return",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.return"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.rotate",
        ui_fields: &["direction"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.rotate"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.select",
        ui_fields: &["objectID"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.select"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.undo",
        ui_fields: &[],
        rewrite_to: None,
        // 宿主契约仍在（`GMGNRadioApp.swift:489` → `world.prop.command{op:"undo"}`），
        // 但这一层已经不再发出它：面板里的「撤销上次」按钮撤掉了。见
        // [`UI_RETIRED_OPS`] —— 该登记保证这条契约不会被误当成「仍然发出」。
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.undo"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.props.withdraw",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.props.withdraw"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.bind",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.bind"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.brightness",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.brightness"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.import",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.import"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.mode",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            // 面板用 tile 的 `id` 命名所选模式；UnityScreenVideoBridge 在改写处把
            // `id` 补成原生 `value`（`native["value"] = native["id"]`），所以这条
            // op 只要求 UI 发 `id`。
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.mode"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.pending.dismiss",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.pending.dismiss"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.pending.play",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.pending.play"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.recoverStop",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.recoverStop"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.remove",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.remove"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.stop",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.stop"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.toggle",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.toggle"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "stage.video.unbind",
        // Unbinding is per current track; the UI no longer names the asset
        // (`stage_panels.rs` `video_asset_actions`).
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", ops: &["stage.video.unbind"], func_anchor: "" },
            // Unity 宿主链: `UnityScreenVideoBridge.command` handles the
            // `stage.video.unbind` arm (the prefix rewrite injects the current
            // `trackID` before renaming to `video.unbind`), so no UI field is
            // required to reach it.
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["stage.video.unbind"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "tts.stop",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/ProductHost/ProductHost.swift", ops: &["tts.stop"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityProductSettings.swift", ops: &["tts.stop"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.bind",
        ui_fields: &["id", "trackID"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.bind"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.bind"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.bound.dismiss",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.bound.dismiss"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.bound.dismiss"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.bound.play",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.bound.play"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.bound.play"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.brightness",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.brightness"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.brightness"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.choose",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.choose"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.choose"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.load",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.load"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.load"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.mode",
        ui_fields: &["value"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.mode"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.mode"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.pause",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.pause"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.pause"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.play",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.play"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.play"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.recoverStop",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.recoverStop"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.remove",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.remove"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.remove"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.select",
        ui_fields: &["id"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.select"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.select"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.stop",
        ui_fields: &[],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.stop"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.stop"], func_anchor: "" },
        ],
    },
    OpContract {
        op: "video.unbind",
        // The handler acts on the current track (`trackID`); the asset `id`
        // only ever rode along and the UI no longer sends it
        // (`settings.rs:2021-2040`).
        ui_fields: &["trackID"],
        rewrite_to: None,
        handlers: &[
            Handler { file: "apps/macos/UnityHost/UnityMediaHost.swift", ops: &["video.unbind"], func_anchor: "" },
            Handler { file: "apps/macos/UnityHost/UnityScreenVideoBridge.swift", ops: &["video.unbind"], func_anchor: "" },
        ],
    },
];

/// `OPS` 里仍然保留、但这一层**不再发出**的 op。
///
/// 格式 `(op, 退役理由)`。两条断言把它钉死：登记的 op 必须仍在 `OPS` 表里
/// （退役的是 UI 发出点，不是宿主契约 —— `op_coverage` 继续要求宿主有处理串），
/// 且它必须**不在** production 源码的 op 字面量里（否则登记过期，说明按钮又回来了）。
///
/// 不许用删表的方式「修」这类过期：删掉就没有任何东西记得宿主还欠一个契约。
const UI_RETIRED_OPS: &[(&str, &str)] = &[(
    "stage.props.undo",
    "面板里的「撤销上次」按钮撤掉了：它坐在正文里、读起来像第二个返回控件。宿主能力保留 —— \
     `GMGNRadioApp.swift:489` 仍把 `stage.props.undo` 翻成 `world.prop.command{op:\"undo\"}`，\
     Unity probe 仍翻译它（`inventory_ui.rs:699`），将来任何界面都能重新发出。",
)];

fn ui_emissions(root: &Path) -> Vec<Emission> {
    let mut files = Vec::new();
    collect(&root.join("apps/gpui-ui/src"), "rs", &mut files);
    files.sort();
    assert!(!files.is_empty(), "apps/gpui-ui/src 下没有 Rust 源码");
    let mut out = Vec::new();
    for file in files {
        let src = fs::read_to_string(&file).unwrap_or_else(|e| panic!("读不到 {}: {e}", file.display()));
        let rel = file.strip_prefix(root).unwrap_or(&file).display().to_string();
        emissions(&rel, &production_source(&src), &mut out);
    }
    out
}

fn read_set(root: &Path, contract: &OpContract, contracts: &[OpContract]) -> (BTreeSet<String>, BTreeMap<String, String>) {
    let mut reads = BTreeSet::new();
    let mut where_ = BTreeMap::new();
    let mut sources: Vec<&OpContract> = vec![contract];
    if let Some(target) = contract.rewrite_to {
        if let Some(t) = contracts.iter().find(|c| c.op == target) {
            sources.push(t);
        }
    }
    for source in sources {
        for handler in source.handlers {
            for (file, line, region) in handler_regions(root, handler) {
                for field in receiver_subscripts(&region) {
                    reads.insert(field.clone());
                    where_.entry(field).or_insert_with(|| format!("{file}:{line}"));
                }
            }
        }
    }
    (reads, where_)
}

fn required_set(root: &Path, contract: &OpContract, contracts: &[OpContract]) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut sources: Vec<&OpContract> = vec![contract];
    if let Some(target) = contract.rewrite_to {
        if let Some(t) = contracts.iter().find(|c| c.op == target) {
            sources.push(t);
        }
    }
    for source in sources {
        for handler in source.handlers {
            for (file, line, region) in handler_regions(root, handler) {
                for field in guard_required(&region) {
                    out.entry(field).or_insert_with(|| format!("{file}:{line}"));
                }
            }
        }
    }
    out
}

#[test]
fn op_field_sets_match_the_source_and_are_read() {
    let root = repo_root();
    let emissions = ui_emissions(&root);
    assert!(!emissions.is_empty(), "没有扫到任何 op 字面量");

    let mut live: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut sites: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for e in &emissions {
        let entry = live.entry(e.op.clone()).or_default();
        for (field, _kind) in &e.fields {
            entry.insert(field.clone());
        }
        sites.entry(e.op.clone()).or_default().push(format!("{}:{}", e.file, e.line));
    }

    let declared: BTreeSet<&str> = OPS.iter().map(|o| o.op).collect();
    assert_eq!(declared.len(), OPS.len(), "OPS 表里有重复 op");

    let undeclared: Vec<&String> = live.keys().filter(|op| !declared.contains(op.as_str())).collect();
    assert!(
        undeclared.is_empty(),
        "UI 发出了 OPS 表里没有登记的 op（新增 op 必须显式登记字段面）：\n{}",
        undeclared
            .iter()
            .map(|op| format!("  {op}  <- {}", sites[*op].join(", ")))
            .collect::<Vec<_>>()
            .join("\n")
    );

    let stale: Vec<&str> = declared
        .iter()
        .copied()
        .filter(|op| !live.contains_key(*op) && !UI_RETIRED_OPS.iter().any(|(retired, _)| retired == op))
        .collect();
    assert!(
        stale.is_empty(),
        "OPS 表里这些 op 在 production 源码里已经不再发出（表过期）：{stale:?}"
    );

    // 已退役的 op 只是不再由这一层发出：宿主处理者仍在（op_coverage 继续钉住），
    // 所以这里既不能按「已发出」对字段面，也不能允许它悄悄回到 OPS 之外。
    for (op, reason) in UI_RETIRED_OPS {
        assert!(
            declared.contains(op),
            "UI_RETIRED_OPS 里 {op} 必须仍留在 OPS 表里（退役的是发出点，不是宿主契约）：{reason}"
        );
        assert!(
            !live.contains_key(*op),
            "UI_RETIRED_OPS 里的 {op} 又出现在 production 源码里了（退役登记过期）：{reason}"
        );
    }

    let mut failures: Vec<String> = Vec::new();
    for contract in OPS {
        if UI_RETIRED_OPS.iter().any(|(retired, _)| *retired == contract.op) {
            continue;
        }
        let emitted = &live[contract.op];
        let declared_fields: BTreeSet<&str> = contract.ui_fields.iter().copied().collect();
        let extra: Vec<&str> = emitted
            .iter()
            .filter(|f| !declared_fields.contains(f.as_str()))
            .map(String::as_str)
            .collect();
        let gone: Vec<&str> = declared_fields
            .iter()
            .copied()
            .filter(|f| !emitted.contains(*f))
            .collect();
        if !extra.is_empty() || !gone.is_empty() {
            failures.push(format!(
                "  {} 字段面与源码不一致（源码多发 {:?}，源码不再发 {:?}）<- {}",
                contract.op,
                extra,
                gone,
                sites[contract.op].join(", ")
            ));
            continue;
        }
        let allowed: BTreeSet<&str> = UNREAD_FIELDS_OK
            .iter()
            .filter(|(op, _, _)| *op == contract.op)
            .map(|(_, field, _)| *field)
            .collect();
        let (reads, _) = read_set(&root, contract, OPS);
        for field in contract.ui_fields {
            if reads.contains(*field) || allowed.contains(field) {
                continue;
            }
            failures.push(format!(
                "  {} 发出的字段 \"{}\" 没有任何声明的宿主处理者读取 <- {}",
                contract.op,
                field,
                sites[contract.op].join(", ")
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "op 字段面不对齐（{} 条）：\n{}",
        failures.len(),
        failures.join("\n")
    );
    eprintln!(
        "interface parity: {} 个 production op，{} 个发出点，字段面与宿主读取一致",
        live.len(),
        emissions.len()
    );
}

#[test]
fn required_fields_are_emitted_by_the_ui() {
    let root = repo_root();
    let emissions = ui_emissions(&root);
    let mut live: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut sites: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for e in &emissions {
        let entry = live.entry(e.op.clone()).or_default();
        for (field, _) in &e.fields {
            entry.insert(field.clone());
        }
        sites.entry(e.op.clone()).or_default().push(format!("{}:{}", e.file, e.line));
    }
    let mut failures = Vec::new();
    for contract in OPS {
        if UI_RETIRED_OPS.iter().any(|(retired, _)| *retired == contract.op) {
            continue;
        }
        let Some(emitted) = live.get(contract.op) else { continue };
        let required = required_set(&root, contract, OPS);
        for (field, at) in &required {
            if field == "op" || emitted.contains(field) {
                continue;
            }
            failures.push(format!(
                "  {} 的宿主处理者 {at} 对字段 \"{field}\" 做了 guard-else-return，\
                 但 UI 从不发这个字段 ⇒ 该请求必被拒；UI 发出点：{}",
                contract.op,
                sites.get(contract.op).map(|s| s.join(", ")).unwrap_or_default()
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "宿主必填字段 UI 没有发出（{} 条）：\n{}",
        failures.len(),
        failures.join("\n")
    );
    eprintln!("interface parity: 每个 op 的宿主必填字段都由 UI 发出");
}

/// 快照子根的生产者：`func_anchor` 指向真正构造该子根的 Swift 计算属性。
const SNAPSHOT_PRODUCERS: &[(&str, &str)] = &[
    ("apps/macos/ProductHost/ProductHost.swift", "var snapshot: [String: Any]"),
    ("apps/macos/ProductHost/ProductSettingsParity.swift", "var snapshot: [String: Any]"),
    ("apps/macos/UnityHost/UnityProductSettings.swift", "var snapshot: [String: Any]"),
];

/// 只有 Unity 宿主会写的 settings 子根键。登记格式 `(key, 写入点 file:line, 产品模式下的处置)`。
/// 产品模式（`GPUIProductSettings.snapshot` + `GPUISettingsParity.snapshot`）不写这些键，
/// 所以这些设置页在产品模式下读到 nil（渲染与否另说）。
const UNITY_ONLY_SNAPSHOT_KEYS: &[(&str, &str, &str)] = &[
    ("characterPosition", "apps/macos/UnityHost/UnityMediaHost.swift:1534", "产品模式无此键 ⇒ 角色位置表单无数据（与 op coverage 的 presence.position 登记同源）"),
    ("generation", "apps/macos/UnityHost/UnityMediaHost.swift:1536", "产品模式改用 space.prop.* 与 space.propEndpoint/propCredentialConfigured，`generation` 页不渲染"),
    ("video", "apps/macos/UnityHost/UnityMediaHost.swift:1537", "产品模式无此键 ⇒ video_page 只在 unity_external 下渲染"),
    ("spaceLibrary", "apps/macos/UnityHost/UnityMediaHost.swift:1538", "产品模式无此键 ⇒ space.library.* 不再渲染（与 op coverage 登记一致）"),
    ("unity", "apps/macos/UnityHost/UnityMediaHost.swift:1548", "产品模式无 `unity.availableSections` ⇒ Unity 专属分组不出现"),
    ("locale", "apps/macos/UnityHost/UnityProductSettings.swift:72", "产品模式无 `locale` ⇒ settings.rs 的语言菜单 `.disabled(true)`（与 op coverage 的 app.language 登记同源）"),
];

/// 一个 Swift 区块里出现的字典键（`"k":` 或 `["k"] =`）。
fn dict_keys(text: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut at = 0usize;
    while let Some((literal, end)) = next_string(text, at) {
        at = end;
        let after = skip_ws(text, end);
        if text.as_bytes().get(after) == Some(&b':') {
            out.insert(literal);
            continue;
        }
        if text.as_bytes().get(after) == Some(&b']') {
            let eq = skip_ws(text, after + 1);
            if text.as_bytes().get(eq) == Some(&b'=') {
                out.insert(literal);
            }
        }
    }
    out
}

#[test]
fn snapshot_keys_read_by_the_ui_are_produced_by_a_host() {
    let root = repo_root();

    // 1) settings 子根：SettingsPane 的 `self.snapshot["k"]` 必须在某个宿主的
    //    settings 快照里被写出来。
    let settings = production_source(&read(&root, "apps/gpui-ui/src/settings.rs"));
    let mut reads: BTreeMap<String, usize> = BTreeMap::new();
    for (i, line) in settings.split('\n').enumerate() {
        let mut at = 0usize;
        while let Some(found) = line[at..].find("self.snapshot[") {
            let open = at + found + "self.snapshot".len();
            let after = skip_ws(line, open + 1);
            let Some((key, end)) = string_at(line, after) else { break };
            if line.as_bytes().get(skip_ws(line, end)) == Some(&b']') {
                reads.entry(key).or_insert(i + 1);
            }
            at = open + 1;
        }
    }
    assert!(!reads.is_empty(), "settings.rs 里没有扫到 self.snapshot[\"…\"]");

    let mut writes = BTreeSet::new();
    for (file, anchor) in SNAPSHOT_PRODUCERS {
        let src = read(&root, file);
        let Some(at) = src.find(anchor) else {
            panic!("{file} 里找不到快照生产者锚点 {anchor:?}")
        };
        let Some(brace) = src[at..].find('{') else { panic!("{file} 的快照生产者没有函数体") };
        let open = at + brace;
        let close = find_close(&src, open, b'{', b'}').unwrap_or(src.len());
        writes.extend(dict_keys(&src[at..close]));
    }
    assert!(!writes.is_empty(), "三个宿主快照生产者里没有解析出任何键");

    let unity_only: BTreeSet<&str> = UNITY_ONLY_SNAPSHOT_KEYS.iter().map(|(k, _, _)| *k).collect();

    let mut failures = Vec::new();
    for (key, line) in &reads {
        if writes.contains(key) || unity_only.contains(key.as_str()) {
            continue;
        }
        failures.push(format!(
            "  apps/gpui-ui/src/settings.rs:{line} 读 snapshot[\"{key}\"],但三个 settings 宿主快照             生产者都没写这个键 ⇒ 永远读到 null"
        ));
    }
    assert!(
        failures.is_empty(),
        "UI 读了没人生成的设置快照键（{} 条）：\n{}",
        failures.len(),
        failures.join("\n")
    );
    // 登记项不能过期：Unity 宿主必须真的还在写这些键。
    let unity_host = read(&root, "apps/macos/UnityHost/UnityMediaHost.swift");
    for (key, at, reason) in UNITY_ONLY_SNAPSHOT_KEYS {
        assert!(
            unity_host.contains(&format!("\"{key}\"")),
            "{key} 登记为「只有 Unity 宿主写」（{at}），但 UnityMediaHost.swift 里已经没有这个键；             登记过期：{reason}"
        );
    }
    eprintln!(
        "interface parity: settings 子根 {} 个 UI 读取键中 {} 个由产品宿主写、{} 个登记为 Unity 宿主独有",
        reads.len(),
        reads.len() - unity_only.len(),
        unity_only.len()
    );

    // 2) ABI 根：overlay 自己读的快照根键必须落在 overlay 的投影白名单里。
    let overlay = read(&root, "tools/fixtures/gpui-unity-overlay-probe/src/lib.rs");
    let start = overlay
        .find("// Retain only UI projections")
        .expect("overlay lib.rs 里找不到快照投影白名单");
    let end = overlay[start..].find(']').expect("白名单没有闭合") + start;
    let allowlist: BTreeSet<String> = {
        let mut at = start;
        let mut keys = BTreeSet::new();
        while let Some((literal, next)) = next_string(&overlay, at) {
            if next > end {
                break;
            }
            keys.insert(literal);
            at = next;
        }
        keys
    };
    assert!(allowlist.len() > 20, "overlay 白名单没解析出来: {allowlist:?}");
    let synthesized: BTreeSet<&str> = ["world"].into_iter().collect();
    let mut overlay_files = Vec::new();
    collect(&root.join("tools/fixtures/gpui-unity-overlay-probe/src"), "rs", &mut overlay_files);
    overlay_files.sort();
    let mut abi_failures = Vec::new();
    let mut abi_reads = 0usize;
    for file in overlay_files {
        let src = fs::read_to_string(&file).unwrap_or_else(|e| panic!("读不到 {}: {e}", file.display()));
        let rel = file.strip_prefix(&root).unwrap_or(&file).display().to_string();
        for (i, line) in src.split('\n').enumerate() {
            let mut at = 0usize;
            while let Some(found) = line[at..].find("snapshot[") {
                let open = at + found + "snapshot".len();
                let after = skip_ws(line, open + 1);
                let Some((key, end)) = string_at(line, after) else { break };
                if line.as_bytes().get(skip_ws(line, end)) != Some(&b']') {
                    at = open + 1;
                    continue;
                }
                abi_reads += 1;
                if !allowlist.contains(&key) && !synthesized.contains(key.as_str()) {
                    abi_failures.push(format!(
                        "  {rel}:{} 读 snapshot[\"{key}\"],但 lib.rs 的 ABI 投影白名单里没有它",
                        i + 1
                    ));
                }
                at = skip_ws(line, end) + 1;
            }
        }
    }
    assert!(abi_reads > 0, "overlay 里没有扫到 snapshot 根键读取");
    assert!(
        abi_failures.is_empty(),
        "overlay 读了投影白名单外的 ABI 根键（{} 条）：\n{}",
        abi_failures.len(),
        abi_failures.join("\n")
    );
    eprintln!("interface parity: overlay {abi_reads} 处 ABI 根键读取全部在投影白名单内");
}

/// 客户端在发、但当前 taskd 一定回 `unknown_method` 的方法。
///
/// 曾经有 9 条：`music_account.rs`/`music_account_http.rs` 与
/// `generation_configuration.rs` 实现存在、Swift 真实调用，但 `main.rs` 的 `mod`
/// 列表里没有它们，所以那份实现根本没被编译进 daemon（音乐账号连接/会话/Apple
/// 授权、许愿机配置保存/检测全部必失败）。
///
/// 它们已经修好：`main.rs` 声明了这两个模块、`daemon.rs` 接上了这 9 个方法，
/// 所以登记项必须删掉——本文件末尾那条断言就是为此写的（"登记项过期即红"），
/// 避免"修好了但登记还留着"把真实缺口掩盖回去。
const KNOWN_UNKNOWN_METHODS: &[(&str, &str, &str)] = &[];

/// 被当成「方法」发出去、其实是**另一个方法的子 op** 的字面量。
/// 它们随 `op`/`op` 字段进入某个真实方法（`music_program_playback_command` 等）。
const SUB_OPERATIONS: &[(&str, &str)] = &[
    ("prepare_receipt", "ProgramPlaybackQueue.swift:149,157 → music_program_playback_command 的 `op`"),
    ("replace_upcoming", "ProgramPlaybackQueue.swift:174 → music_program_playback_command 的 `op`"),
    ("current_failed", "ProgramPlaybackQueue.swift:184 → music_program_playback_command 的 `op`"),
];

/// 非 taskd JSON-RPC 的方法名：属于别的协议或别的层。必须写明归属。
const NON_TASKD_METHODS: &[(&str, &str)] = &[
    ("initialize", "codex/DSH JSON-RPC（ResidentCodexTransport.swift:223、ResidentDSHTransport.swift:207）"),
    ("initialized", "codex JSON-RPC 通知（ResidentCodexAgent.swift）"),
    ("config/read", "codex JSON-RPC（ResidentCodexAgent.swift:116）"),
    ("thread/start", "codex JSON-RPC（ResidentCodexAgent.swift:152 的 method 变量）"),
    ("turn/start", "codex JSON-RPC（ResidentCodexAgent.swift:164）"),
    ("turn/steer", "codex JSON-RPC（ResidentCodexAgent.swift:215）"),
    ("session/new", "DSH/ACP JSON-RPC（ResidentDSHTransport.swift:217）"),
    ("session/prompt", "DSH/ACP JSON-RPC（ResidentDSHTransport.swift:270）"),
];

/// 只认**方法位**上的字面量：`method: "x"` / `"method": "x"` / `subscribe("x")`。
/// 错误码、子 op（`request("prepare_receipt")`）、断言里的字符串都不算——
/// 这条门禁要盯的是 JSON-RPC 信封的 `method` 字段。
fn method_position_literals(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    for pattern in ["\"method\":", "method:"] {
        let mut from = 0usize;
        while let Some(at) = line[from..].find(pattern) {
            let at = from + at + pattern.len();
            from = at;
            if let Some((literal, end)) = next_string(line, at) {
                out.push(literal);
                from = end;
            }
        }
    }
    for pattern in ["subscribe(", "transport(", "request(", "rpc(", "perform("] {
        let mut from = 0usize;
        while let Some(at) = line[from..].find(pattern) {
            let at = from + at + pattern.len();
            from = at;
            if let Some((literal, end)) = next_string(line, at) {
                out.push(literal);
                from = end;
            }
        }
    }
    out
}

#[test]
fn client_rpc_methods_are_accepted_by_the_authority() {
    let root = repo_root();
    let daemon = read(&root, "services/gmgn-taskd/src/daemon.rs");
    let http = read(&root, "services/gmgn-taskd/src/http.rs");
    let main = read(&root, "services/gmgn-taskd/src/main.rs");

    // 1) `match method { … }` 里接受的 236 个方法（多行 `|` 臂要续行累加）。
    let match_at = daemon.find("match method {").expect("daemon.rs 里没有 match method");
    let mut accepted: BTreeSet<String> = BTreeSet::new();
    let mut buf = String::new();
    for line in daemon[match_at..].split('\n').skip(1) {
        if line.trim_start().starts_with("_ =>") {
            break;
        }
        let t = line.trim_start();
        if buf.is_empty() && !(t.starts_with('"') || t.starts_with('|')) {
            continue;
        }
        buf.push_str(line);
        buf.push(' ');
        if line.contains("=>") {
            let pattern = buf.split("=>").next().unwrap_or("").to_owned();
            let mut at = 0usize;
            while let Some((literal, end)) = next_string(&pattern, at) {
                accepted.insert(literal);
                at = end;
            }
            buf.clear();
        }
    }
    assert!(accepted.len() > 200, "daemon 方法表只解析出 {} 条", accepted.len());

    // 2) 事件流的三个方法与 voice_* 走别的路径。
    for extra in ["subscribe", "subscribe_messages", "world_subscribe"] {
        accepted.insert(extra.to_owned());
    }
    assert!(http.contains("envelope.method.starts_with(\"voice_\")"), "voice 路由变了");
    for method in ["voice_list", "voice_capabilities", "voice_tts_start", "voice_asr_start",
                   "voice_audio_append", "voice_asr_commit", "voice_cancel"] {
        if http.contains(&format!("\"{method}\"")) {
            accepted.insert(method.to_owned());
        }
    }
    // 已知的 unknown_method 缺口：模块存在但没进 main.rs 的 `mod` 列表，所以
    // 这些方法在真 daemon 上必然得到 `unknown_method`。登记一条就要能证明它**现在**
    // 仍然是缺口：修好之后（模块被注册）这条断言会红，逼着删掉登记项。
    for (method, module, reason) in KNOWN_UNKNOWN_METHODS {
        assert!(
            !main.contains(&format!("mod {module};")),
            "{method} 登记为「权威不认」，但 `mod {module};` 已经补进 main.rs ⇒ 登记过期，             请删除该条目并确认调用链：{reason}"
        );
    }

    // 3) 客户端方法字面量。
    let mut files = Vec::new();
    for tree in ["apps/macos", "apps/gpui-app", "tools/fixtures/gpui-unity-overlay-probe"] {
        collect(&root.join(tree), "swift", &mut files);
        collect(&root.join(tree), "rs", &mut files);
    }
    files.sort();
    let non_taskd: BTreeSet<&str> = NON_TASKD_METHODS.iter().map(|(m, _)| *m).collect();
    let known_gap: BTreeSet<&str> = KNOWN_UNKNOWN_METHODS.iter().map(|(m, _, _)| *m).collect();
    let sub_ops: BTreeSet<&str> = SUB_OPERATIONS.iter().map(|(m, _)| *m).collect();
    let mut unknown: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut scanned: BTreeSet<String> = BTreeSet::new();
    let mut seen = 0usize;
    for file in files {
        let Ok(src) = fs::read_to_string(&file) else { continue };
        if !src.contains("\"method\"") && !src.contains("method:") && !src.contains("call(method") {
            continue;
        }
        let rel = file.strip_prefix(&root).unwrap_or(&file).display().to_string();
        for (i, line) in src.split('\n').enumerate() {
            for literal in method_position_literals(line) {
                if !literal.contains('_')
                    || !literal
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c == '_' || c.is_ascii_digit())
                {
                    continue;
                }
                seen += 1;
                scanned.insert(literal.clone());
                if accepted.contains(&literal)
                    || non_taskd.contains(literal.as_str())
                    || known_gap.contains(literal.as_str())
                    || sub_ops.contains(literal.as_str())
                {
                    continue;
                }
                unknown.entry(literal).or_default().push(format!("{rel}:{}", i + 1));
            }
        }
    }
    // 扫描口径自检：这些方法名是源码里以 `method: "…"` 直发的方法位字面量，
    // 少了任何一条说明扫描退化了（大多数调用点把方法名存进变量，不走字面量）。
    const MUST_BE_SEEN: [&str; 8] = [
        "world_snapshot",
        "world_facts_read",
        "state_read",
        "state_commit",
        "memory_recall",
        "music_account_session",
        "generation_configuration_read",
        "voice_capabilities",
    ];
    let all_sites: BTreeSet<String> = accepted
        .iter()
        .cloned()
        .chain(non_taskd.iter().map(|s| (*s).to_owned()))
        .chain(known_gap.iter().map(|s| (*s).to_owned()))
        .collect();
    let missing: Vec<&str> = MUST_BE_SEEN
        .iter()
        .copied()
        .filter(|m| !scanned.contains(*m))
        .collect();
    assert!(
        missing.is_empty(),
        "扫描口径退化：这些方法位字面量没有被扫到 {missing:?}（已扫 {seen} 条，\n\
         daemon 接受面 {all} 条）",
        all = all_sites.len()
    );
    assert!(seen >= 20, "方法字面量只扫到 {seen} 条，扫描口径可能失效");
    assert!(
        unknown.is_empty(),
        "客户端发了权威不认的方法（{} 个）：\n{}",
        unknown.len(),
        unknown
            .iter()
            .map(|(m, sites)| format!("  {m}  <- {}", sites.join(", ")))
            .collect::<Vec<_>>()
            .join("\n")
    );
    eprintln!("interface parity: {seen} 个客户端方法字面量全部落在 taskd 接受面或显式登记的非 taskd 协议里");
}

#[test]
fn tool_schema_types_are_supported_by_the_authority() {
    let root = repo_root();
    let authority = read(&root, "services/gmgn-taskd/src/agent_tools.rs");
    // agent_tools.rs 的 valid_type 词表。
    let known: BTreeSet<&str> = ["object", "array", "string", "boolean", "integer", "number", "null"]
        .into_iter()
        .collect();
    assert!(
        authority.contains("duplicate-free non-empty union of at most 7"),
        "agent_tools.rs 的联合类型校验描述变了，请重读 schema_defect"
    );

    // 真正会把 inputSchema 交给权威的生产者树。
    const TOOL_SCHEMA_ROOTS: [&str; 4] = [
        "apps/macos/UnityHost",
        "apps/macos/ProductHost",
        "apps/macos/Sources/GMGNRadio/Agent",
        "apps/macos/Sources/GMGNRadio/Screen",
    ];
    let mut files = Vec::new();
    for tree in TOOL_SCHEMA_ROOTS {
        collect(&root.join(tree), "swift", &mut files);
    }
    files.sort();
    let mut failures = Vec::new();
    let mut found = 0usize;
    for file in files {
        let Ok(src) = fs::read_to_string(&file) else { continue };
        let rel = file.strip_prefix(&root).unwrap_or(&file).display().to_string();
        for (i, line) in src.split('\n').enumerate() {
            let Some(at) = line.find("\"type\": [") else { continue };
            let open = at + "\"type\": ".len();
            let Some(close) = find_close(line, open, b'[', b']') else { continue };
            let body = &line[open + 1..close];
            let mut alternatives = Vec::new();
            let mut cursor = 0usize;
            while let Some((literal, end)) = string_at(body, cursor) {
                alternatives.push(literal);
                cursor = end;
            }
            found += 1;
            let bad: Vec<&String> = alternatives.iter().filter(|t| !known.contains(t.as_str())).collect();
            if alternatives.is_empty() || alternatives.len() > 7 || !bad.is_empty() {
                failures.push(format!(
                    "  {rel}:{} 的 type 联合 {:?} 不被 agent_tools.rs 接受（未知类型 {:?}）",
                    i + 1, alternatives, bad
                ));
            }
        }
    }
    assert!(found > 0, "没有扫到任何 `\"type\": [` 联合类型，前提变了");
    assert!(
        failures.is_empty(),
        "工具 schema 的联合类型会被注册校验拒绝（{} 条）：\n{}",
        failures.len(),
        failures.join("\n")
    );
    eprintln!("interface parity: {found} 处 type 联合全部落在 agent_tools.rs 的类型词表内（当前为 [\"object\",\"null\"]）");
}

/// `stage.load` used to be a fake success: the Unity host answered `true` and
/// ran nothing (`docs/plans/2026-10-08-ui-function-verification.md` §4.2), so
/// the UI showed an accepted settings command that no authority ever confirmed.
/// The fix has two halves and this test fails if either is undone:
///
/// 1. the GPUI sources do not emit the op any more — there is no production
///    action behind it (the stage projection arrives with every snapshot);
/// 2. the Unity host's two arms for it answer `false`, which becomes
///    `settingsCommandResult.status=failed` (`code
///    settings_command_rejected`) instead of `accepted`.
///
/// The op name is not deleted: it stays in [`OPS`] and in the host's
/// `supportedCommands`, so a stale caller gets a named failure instead of the
/// generic 「当前运行时不支持此操作」 path.
#[test]
fn stage_load_is_answered_not_faked() {
    let root = repo_root();
    let mut sources = Vec::new();
    collect(&root.join("apps/gpui-ui/src"), "rs", &mut sources);
    collect(
        &root.join("tools/fixtures/gpui-unity-overlay-probe/src"),
        "rs",
        &mut sources,
    );
    sources.sort();
    // The op name is documented in comments/constants on purpose; a code line
    // that mentions it is the emission this test forbids. The whole file is
    // scanned (not `production_source`): this test also covers the overlay
    // fixture tree, and the forbidden shape is a *code line that mentions the
    // op*, not a production-only one — stripping test modules would only make
    // the forbidden emission easier to hide.
    let mut emitters = Vec::new();
    for file in &sources {
        let Ok(src) = fs::read_to_string(file) else { continue };
        let rel = file.strip_prefix(&root).unwrap_or(&file).display().to_string();
        for (i, line) in src.split('\n').enumerate() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("//")
                || trimmed.starts_with("/*")
                || trimmed.starts_with('*')
                || line.contains("STAGE_LOAD_OP")
            {
                continue;
            }
            if line.contains("\"op\"") && line.contains("\"stage.load\"") {
                emitters.push(format!("{rel}:{}", i + 1));
            }
        }
    }
    assert!(
        emitters.is_empty(),
        "没有任何生产动作支撑 `stage.load`，UI 不能再发出它（会拿到一个必然失败的设置命令）：{emitters:?}"
    );

    let host = read(&root, "apps/macos/UnityHost/UnityMediaHost.swift");
    let mut arms = 0usize;
    for (i, line) in host.split('\n').enumerate() {
        if !line.contains("case \"stage.load\":") {
            continue;
        }
        arms += 1;
        let tail = line
            .split("case \"stage.load\":")
            .nth(1)
            .unwrap_or_default()
            .trim();
        assert!(
            !tail.contains("return true"),
            "UnityMediaHost.swift:{} 的 `stage.load` 又回到假成功（`return true`）",
            i + 1
        );
        assert!(
            tail.contains("return false"),
            "UnityMediaHost.swift:{} 的 `stage.load` 必须回 `false`（由此变成 \
             settingsCommandResult.status=failed），实际是 {tail:?}",
            i + 1
        );
    }
    assert_eq!(
        arms, 2,
        "UnityMediaHost.swift 里应有两条 `stage.load` 分支（command(_:) 与 settingsCommand(_:)）"
    );
}
