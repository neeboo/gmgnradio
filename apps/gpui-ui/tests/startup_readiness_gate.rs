//! 启动就绪门禁（2026-10-09）：**加载态结束后不得再出现"没 ready"文案**。
//!
//! 对象是 [`gmgn_gpui_ui::startup`]：那份穷举清单、那台并行有界具名失败的状态机、
//! 以及把"以前进门之后才看到的没 ready 文案"逐条收走的登记表。
//!
//! 四条断言，每条都能红，且都给出**为什么**：
//!
//! 1. [`every_readiness_item_cites_a_live_source_line`] —— 清单每一项的
//!    `source`（`仓库相对路径:行`）必须真的存在、那一行必须真的非空。一句
//!    "某处会失败"不算证据；指到行才算。
//! 2. [`every_known_not_ready_sentence_is_retired_by_a_gate_item`] —— 每条
//!    "进门之后才看到的没 ready"文案必须（a）在它引用的那一行**逐字还在**、
//!    （b）绑定到一个**真的存在**的加载态项、且（c）两项的处置（挡人 /
//!    具名不挡人 / 进门后按需）与那一项的角色一致。
//! 3. [`no_unregistered_not_ready_sentence_survives_the_scan`] —— 机械扫描
//!    `SCANNED_SOURCES` 的**字符串字面量**（注释与测试模块被剥掉），命中
//!    `NOT_READY_PATTERNS` 的每一条都必须在登记表里出现。**新增一句没登记的
//!    "没 ready" ⇒ 红。**
//! 4. [`the_gate_is_bounded_and_never_fails_silently`] —— 空信号下推进到整体
//!    上界，必须得到 `Blocked` **加上**一个具名失败；每个挡人项都有自己的上界；
//!    超时码只能是 `<id>_timeout` / `<id>_deadline` / `<id>_blocked_by_*`。
//!
//! ## 两条**可执行的负对照**
//!
//! 判据本身也要能被判红，否则"从不 FAIL 的门禁等于没有门禁"。所以两个最关键的
//! 检查被抽成接受"登记表/清单"参数的纯函数，测试用**删掉一项**的副本再跑一遍，
//! 断言它**确实变红**：
//!
//! - [`moving_an_item_out_of_the_gate_turns_the_coverage_check_red`]：把任一
//!   `gate_item` 从清单里去掉，覆盖检查必须报出悬空绑定；
//! - [`unregistering_a_sentence_turns_the_scan_red`]：把任一登记项从表里去掉，
//!   扫描必须报出未登记的那一句。
//!
//! ## 扫描面为什么是这一串，而不是整棵树
//!
//! 逐个钉住（[`SCANNED_SOURCES`]）而不是整树扫：面越大，越容易把**别的线正在写
//! 的文件**变成假红。`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
//! （10k 行、正在被别的线改）**刻意不在**扫描面内，它的"没 ready"文案由
//! [`RETIRED_COPY`]/[`ALLOWED_AFTER_READY`] 的**逐条精确引用**冻结。
//! `apps/gpui-ui/src/startup.rs`（就是这台加载态自己）在扫描前会把
//! `pub const STARTUP_ITEMS` / `RETIRED_COPY` / `ALLOWED_AFTER_READY` /
//! `NOT_READY_PATTERNS` 四块**整体抹白**再扫——否则登记表会扫到自己（循环），
//! 抹白这件事本身也有断言（[`the_registry_blanking_is_not_a_noop`]），
//! 一条不再抹白的变换会让这条门禁静默失效，所以它必须红。

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use gmgn_gpui_ui::startup::{
    ALLOWED_AFTER_READY, Disposition, GateRole, NOT_READY_PATTERNS, REGISTRY_CONST_NAMES, RETIRED_COPY,
    SCANNED_SOURCES, SILENT_BEFORE_THE_GATE, STARTUP_DEADLINE_MS, STARTUP_ITEMS, ScanLang, StartupGate,
    StartupPhase, StartupSignals, StepPhase, readiness_item,
};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("apps/gpui-ui lives in <repo>/apps")
        .to_path_buf()
}

fn source_of(relative: &str) -> String {
    let path = repo_root().join(relative);
    fs::read_to_string(&path).unwrap_or_else(|error| panic!("{} must be readable: {error}", path.display()))
}

/// 这台加载态自己的文件：它是**唯一**允许写"不带行号"的来源。
const GATE_SOURCE: &str = "apps/gpui-ui/src/startup.rs";

/// `仓库相对路径:行` → `(路径, Some(行))`。
///
/// 只有 [`GATE_SOURCE`] 可以写成不带行号的 `仓库相对路径`：它的**面板文案**就在
/// 自己身上，行号会随它每一处编辑而移动，逐行钉住只会把这条门禁变成噪音。别的一切
/// 来源**必须**给行号——"某处会失败"不算证据，指到行才算。
fn split_citation(citation: &str) -> (&str, Option<usize>) {
    match citation.rsplit_once(':') {
        Some((path, line)) if !line.is_empty() && line.chars().all(|c| c.is_ascii_digit()) => {
            (path, Some(line.parse().unwrap_or_else(|_| panic!("{citation} must end in a line number"))))
        }
        _ => {
            assert_eq!(
                citation, GATE_SOURCE,
                "{citation} must be `path:line`; only the gate's own file may drop the line"
            );
            (citation, None)
        }
    }
}

/// 引用是否真的指到了那句话。
fn citation_is_live(citation: &str, sentence: &str) -> Result<(), String> {
    let (path, line) = split_citation(citation);
    let source = source_of(path);
    match line {
        Some(line) => match source.lines().nth(line - 1) {
            None => Err(format!("{citation} ({sentence}) 已经不存在")),
            Some(text) if !line_carries_sentence(text, sentence) => {
                Err(format!("{citation} 那一行不再写着「{sentence}」"))
            }
            Some(_) => Ok(()),
        },
        None => {
            if source.contains(sentence) {
                Ok(())
            } else {
                Err(format!("{path} 里不再写着「{sentence}」"))
            }
        }
    }
}

/// 那一行是否**真的**还写着这句话。
///
/// `\` 在 Swift/C# 里是字符串插值语法（`\(who)`），不是文案的一部分，所以两边都
/// 把反斜杠丢掉再比：这样"句子还在不在"这件事与宿主语言的转义写法无关。
fn line_carries_sentence(line: &str, sentence: &str) -> bool {
    line.contains(sentence) || line.replace('\\', "").contains(&sentence.replace('\\', ""))
}

// ---------------------------------------------------------------------------
// 判据 1：引用必须指到真的行
// ---------------------------------------------------------------------------

#[test]
fn every_readiness_item_cites_a_live_source_line() {
    let mut failures = Vec::new();
    for item in STARTUP_ITEMS {
        let (path, line) = split_citation(item.source);
        let line = line.unwrap_or_else(|| panic!("{} must cite a line, not a whole file", item.id));
        let source = source_of(path);
        let lines: Vec<&str> = source.lines().collect();
        if line == 0 || line > lines.len() {
            failures.push(format!("{}: {} is outside {} ({} lines)", item.id, item.source, path, lines.len()));
            continue;
        }
        if lines[line - 1].trim().is_empty() {
            failures.push(format!("{}: {} points at a blank line", item.id, item.source));
        }
    }
    assert!(failures.is_empty(), "the checklist must cite real lines:\n{}", failures.join("\n"));
}

// ---------------------------------------------------------------------------
// 判据 2：每条"没 ready"文案都被加载态里的一项收走
// ---------------------------------------------------------------------------

/// 覆盖检查，**接受一份清单**——负对照就是给它一份删掉某一项的清单。
fn dangling_bindings(items: &[&gmgn_gpui_ui::startup::ReadinessItem]) -> Vec<String> {
    let mut failures = Vec::new();
    let ids: BTreeSet<&str> = items.iter().map(|item| item.id).collect();
    for entry in RETIRED_COPY {
        if !ids.contains(entry.gate_item) {
            failures.push(format!(
                "「{}」绑定到 {}，但这一项不在加载态里",
                entry.text, entry.gate_item
            ));
            continue;
        }
        let item = items.iter().find(|item| item.id == entry.gate_item).expect("checked above");
        let expected = match entry.disposition {
            Disposition::Blocks => GateRole::Blocking,
            Disposition::NamedAtStartup => GateRole::Preflight,
            Disposition::Deferred => GateRole::Deferred,
        };
        if item.role != expected {
            failures.push(format!(
                "「{}」的处置与 {} 的角色不一致",
                entry.text, entry.gate_item
            ));
        }
        if entry.why.trim().is_empty() {
            failures.push(format!("「{}」没有写明为什么这样收", entry.text));
        }
    }
    failures
}

#[test]
fn every_known_not_ready_sentence_is_retired_by_a_gate_item() {
    let items: Vec<&_> = STARTUP_ITEMS.iter().collect();
    let failures = dangling_bindings(&items);
    assert!(failures.is_empty(), "the checklist must cover every retired sentence:\n{}", failures.join("\n"));

    // 每条文案在它引用的那一行必须逐字还在——句子挪了、删了，都要重新做一次决定。
    let mut stale = Vec::new();
    for entry in RETIRED_COPY {
        if let Err(problem) = citation_is_live(entry.source, entry.text) {
            stale.push(problem);
        }
    }
    assert!(stale.is_empty(), "retired copy must stay pinned to its line:\n{}", stale.join("\n"));

    // 每个挡人项都要有人替它说话：要么它在 RETIRED_COPY 里收走了一句真文案，
    // 要么它在 SILENT_BEFORE_THE_GATE 里写明"以前静默在哪一行"。两者都没有的
    // 挡人项就是"挡住了人却不说为什么"。
    let bound: BTreeSet<&str> = RETIRED_COPY.iter().map(|entry| entry.gate_item).collect();
    let silent: BTreeSet<&str> = SILENT_BEFORE_THE_GATE.iter().map(|(id, _)| *id).collect();
    let unbound: Vec<&str> = STARTUP_ITEMS
        .iter()
        .filter(|item| {
            item.role == GateRole::Blocking && !bound.contains(item.id) && !silent.contains(item.id)
        })
        .map(|item| item.id)
        .collect();
    assert!(
        unbound.is_empty(),
        "every blocking item must either retire a real sentence or be named in \
         SILENT_BEFORE_THE_GATE with the line that used to fail silently: {unbound:?}"
    );
    let mut named_silent = Vec::new();
    for (id, why) in SILENT_BEFORE_THE_GATE {
        assert!(
            STARTUP_ITEMS.iter().any(|item| item.id == *id && item.role == GateRole::Blocking),
            "{id} is registered as silent-before-the-gate but is not a blocking item"
        );
        assert!(!why.trim().is_empty(), "{id} must say where it used to fail silently");
        named_silent.push(*id);
    }
    assert!(!named_silent.is_empty(), "the silent table must not be empty");
}

#[test]
fn moving_an_item_out_of_the_gate_turns_the_coverage_check_red() {
    let full: Vec<&_> = STARTUP_ITEMS.iter().collect();
    assert!(dangling_bindings(&full).is_empty(), "the full checklist must be green first");
    let mut turned_red = 0;
    for removed in STARTUP_ITEMS {
        let pruned: Vec<&_> = STARTUP_ITEMS.iter().filter(|item| item.id != removed.id).collect();
        if !dangling_bindings(&pruned).is_empty() {
            turned_red += 1;
        }
    }
    assert!(
        turned_red > 0,
        "removing an item from the gate must dangle at least one retired sentence; \
         otherwise this gate cannot fail and proves nothing"
    );
    // 把**全部**挡人项拿掉，必须红成一片（不是"恰好碰到一条"）。
    let without_blocking: Vec<&_> = STARTUP_ITEMS
        .iter()
        .filter(|item| item.role != GateRole::Blocking)
        .collect();
    assert!(
        dangling_bindings(&without_blocking).len() >= 5,
        "dropping every blocking item must dangle the whole pre-entry set"
    );
}

#[test]
fn every_allowance_states_a_reason_and_stays_pinned() {
    let mut failures = Vec::new();
    for allowance in ALLOWED_AFTER_READY {
        if allowance.why.trim().is_empty() {
            failures.push(format!("「{}」没有写明为什么可以进门后再出现", allowance.text));
        }
        if let Err(problem) = citation_is_live(allowance.source, allowance.text) {
            failures.push(problem);
        }
    }
    assert!(failures.is_empty(), "every exemption needs a live line and a reason:\n{}", failures.join("\n"));
}

// ---------------------------------------------------------------------------
// 判据 3：机械扫描
// ---------------------------------------------------------------------------

/// 把 `pub const NAME` 到紧跟的顶格 `];` 之间整体抹白（保留换行）。
///
/// 这台加载态自己的四个常量里写的**就是**这份文案清单，扫它们等于扫自己。
fn blank_top_level_consts(src: &str, names: &[&str]) -> String {
    let mut out = String::with_capacity(src.len());
    let mut lines: Vec<&str> = src.lines().collect();
    let mut blanked = 0usize;
    let mut skipping = false;
    let mut index = 0usize;
    while index < lines.len() {
        let line = lines[index];
        if !skipping {
            if names.iter().any(|name| line.trim_start().starts_with(&format!("pub const {name}")))
                && line.contains('=')
            {
                skipping = true;
                blanked += 1;
                out.push_str(&" ".repeat(line.chars().count()));
                out.push('\n');
                if line.trim_end().ends_with("];") {
                    skipping = false;
                }
                index += 1;
                continue;
            }
        } else {
            out.push_str(&" ".repeat(line.chars().count()));
            out.push('\n');
            if line.trim_end() == "];" {
                skipping = false;
            }
            index += 1;
            continue;
        }
        out.push_str(line);
        out.push('\n');
        index += 1;
    }
    lines.clear();
    if blanked == 0 {
        // 变换失效就是门禁失效：宁可红。
        return String::new();
    }
    out
}

fn scanned_text(relative: &str, lang: ScanLang) -> String {
    let source = source_of(relative);
    match lang {
        ScanLang::Rust => blank_rust_test_modules(&source),
        ScanLang::RustGate => blank_rust_test_modules(&blank_top_level_consts(&source, REGISTRY_CONST_NAMES)),
        ScanLang::CLike => source,
    }
}

/// 注册表里所有"已经被决定过"的句子。
fn registered_sentences() -> Vec<&'static str> {
    RETIRED_COPY
        .iter()
        .map(|entry| entry.text)
        .chain(ALLOWED_AFTER_READY.iter().map(|entry| entry.text))
        .collect()
}

fn is_registered(body: &str, registered: &[&str]) -> bool {
    registered.iter().any(|entry| body.contains(*entry) || entry.contains(body))
}

/// 扫描面里**命中"没 ready"句式**的全部字面量，带来源与行号。
///
/// 只读一次：负对照要对同一批字面量跑很多次"换了注册表还认不认"，每次都重读
/// 二十几个文件（其中 `settings.rs` 五千行）会把一条门禁变成几分钟的 IO。
fn scanned_literals() -> Vec<(String, usize, String)> {
    let mut out = Vec::new();
    for (relative, lang) in SCANNED_SOURCES {
        let source = scanned_text(relative, *lang);
        for (line, body) in string_literals(&source, *lang) {
            if NOT_READY_PATTERNS.iter().any(|pattern| body.contains(*pattern)) {
                out.push(((*relative).to_owned(), line, body));
            }
        }
    }
    out
}

/// 这批字面量里**没有登记**的那些。负对照就是给它一份截短的注册表。
fn unregistered_among(literals: &[(String, usize, String)], registered: &[&str]) -> Vec<(String, usize, String)> {
    literals
        .iter()
        .filter(|(_, _, body)| !is_registered(body, registered))
        .cloned()
        .collect()
}

fn unregistered_sentences(registered: &[&str]) -> Vec<(String, usize, String)> {
    unregistered_among(&scanned_literals(), registered)
}

#[test]
fn no_unregistered_not_ready_sentence_survives_the_scan() {
    let registered = registered_sentences();
    let unregistered = unregistered_sentences(&registered);
    assert!(
        unregistered.is_empty(),
        "these not-ready sentences are not in RETIRED_COPY / ALLOWED_AFTER_READY — \
         decide for each one: bind it to a startup item, or exempt it with a reason:\n{}",
        unregistered
            .iter()
            .map(|(file, line, body)| format!("  {file}:{line}\t{}", body.trim()))
            .collect::<Vec<_>>()
            .join("\n")
    );
    // 扫描面本身不许退化成空：一条不再扫任何文件的门禁等于没有门禁。
    assert!(SCANNED_SOURCES.len() >= 20, "the scan must cover the real surfaces");
    assert!(
        SCANNED_SOURCES.iter().any(|(path, _)| path.contains("UnityWorldBridge") || path.contains("WorldRuntimeBridge")),
        "the world-prepare copy is the core of this gate"
    );
    // 登记表也不许退化成空。
    assert!(RETIRED_COPY.len() >= 20, "the retired-copy table must stay exhaustive");
    for entry in RETIRED_COPY {
        assert!(!entry.text.is_empty() && !entry.source.is_empty() && !entry.why.is_empty());
    }
    for allowance in ALLOWED_AFTER_READY {
        assert!(
            !allowance.text.is_empty() && !allowance.source.is_empty() && !allowance.why.is_empty()
        );
    }
}

#[test]
fn unregistering_a_sentence_turns_the_scan_red() {
    let registered = registered_sentences();
    assert!(unregistered_sentences(&registered).is_empty(), "the full table must be green first");
    let literals = scanned_literals();
    let mut turned_red = 0;
    for text in &registered {
        let pruned: Vec<&str> = registered.iter().copied().filter(|entry| entry != text).collect();
        if !unregistered_among(&literals, &pruned).is_empty() {
            turned_red += 1;
        }
    }
    assert!(
        turned_red >= 5,
        "removing entries from the registry must make the scan red for the sentences they covered; \
         only {turned_red} did"
    );
}

#[test]
fn the_registry_blanking_is_not_a_noop() {
    let source = source_of("apps/gpui-ui/src/startup.rs");
    let blanked = blank_top_level_consts(&source, REGISTRY_CONST_NAMES);
    assert!(!blanked.is_empty(), "the blanking must find its four constants, not silently copy the file");
    assert_eq!(blanked.lines().count(), source.lines().count(), "line numbers must survive blanking");
    assert!(
        !blanked.contains("pub const STARTUP_ITEMS"),
        "the registry must be blanked before the scan"
    );
    // 抹白之后，这台加载态自己的字面量**仍然**被扫（否则就是把整个文件排除掉了）。
    let gate_literals = string_literals(&blank_rust_test_modules(&blanked), ScanLang::RustGate);
    assert!(
        gate_literals.iter().any(|(_, body)| body.contains("正在进入生活空间")),
        "the pane's own copy must still be scanned"
    );
    assert!(
        !gate_literals.iter().any(|(_, body)| body.contains("空间画面准备超时")),
        "the registry's sentences must be blanked out of the scan"
    );
}

// ---------------------------------------------------------------------------
// 判据 4：有上界、失败具名
// ---------------------------------------------------------------------------

#[test]
fn the_gate_is_bounded_and_never_fails_silently() {
    assert!(STARTUP_DEADLINE_MS > 0, "a loading surface without a bound waits forever");
    // 每个挡人项都有自己的上界，而且不荒谬（不超过整体上界的一倍）。
    for item in STARTUP_ITEMS.iter().filter(|item| item.role == GateRole::Blocking)
    {
        assert!(item.budget_ms > 0, "{} has no bound", item.id);
        assert!(
            item.budget_ms <= STARTUP_DEADLINE_MS * 2,
            "{} budgets {} ms, past any sensible deadline",
            item.id,
            item.budget_ms
        );
    }
    // 并行：一次 `observe` 里，所有依赖已满足的项**一起**开始，不是一项一次。
    let mut parallel = StartupGate::new();
    let mut only_core = StartupSignals::new();
    only_core.set(gmgn_gpui_ui::startup::Signal::HostCore, true);
    parallel.observe(&only_core, 0);
    let running: Vec<&str> = parallel
        .steps()
        .into_iter()
        .filter(|view| view.phase == StepPhase::Running)
        .map(|view| view.id)
        .collect();
    assert!(
        running.len() >= 3,
        "one observation must start every ready dependency level at once, started {running:?}"
    );
    assert_eq!(parallel.step("host.core").unwrap().phase, StepPhase::Ready);
    // 空信号：到点必须 Blocked + 具名，而不是一直 Preparing。
    let mut gate = StartupGate::new();
    let signals = StartupSignals::new();
    assert_eq!(gate.observe(&signals, 0), StartupPhase::Preparing);
    assert_eq!(
        gate.observe(&signals, STARTUP_DEADLINE_MS + 1),
        StartupPhase::Blocked,
        "the gate must end, and end with a verdict"
    );
    let failure = gate.failure().expect("Blocked must come with a named failure");
    assert!(!failure.label.is_empty() && !failure.message.is_empty());
    assert!(!failure.code.is_empty());
    assert!(failure.retryable, "a bounded failure must be retryable");
    for view in gate.steps() {
        if matches!(view.phase, StepPhase::Failed | StepPhase::Unavailable | StepPhase::Deferred) {
            let code = view.code.as_deref().unwrap_or("");
            assert!(!code.is_empty(), "{} ended in {:?} with no code", view.id, view.phase);
            assert!(
                code.ends_with("_timeout")
                    || code.ends_with("_deadline")
                    || code.ends_with("_unavailable")
                    || code.contains("_blocked_by_")
                    || code.ends_with("_after_entry"),
                "{} carries an unrecognised code {code}",
                view.id
            );
        }
    }
    // 上界是**两道**，而且两道都是载荷：
    // (1) 每一项自己的 `budget_ms`：把整体上界放到无穷大，它仍然会给出结局。
    let mut no_overall = StartupGate::with_deadline(u64::MAX);
    assert_eq!(no_overall.observe(&signals, 0), StartupPhase::Preparing);
    assert_eq!(
        no_overall.observe(&signals, 6_000),
        StartupPhase::Blocked,
        "per-item budgets alone must end the wait — otherwise a huge overall bound hides it"
    );
    // (2) 整体上界：它必须有限，而且不小于最大的单项预算（不能抢在合法准备之前收口）。
    assert!(STARTUP_DEADLINE_MS > 0);
    let largest = STARTUP_ITEMS.iter().map(|item| item.budget_ms).max().unwrap_or(0);
    assert!(
        STARTUP_DEADLINE_MS >= largest,
        "the overall deadline must not pre-empt a legitimate {largest} ms single step"
    );
}

#[test]
fn a_named_unavailable_item_does_not_keep_anyone_out() {
    // 关掉物理探针信号、其余全给：`world.physics` 是 Preflight，它只能变成
    // 具名不可用，不能把整体判成 Blocked。
    let mut gate = StartupGate::with_deadline(STARTUP_DEADLINE_MS);
    let mut signals = StartupSignals::new();
    for item in STARTUP_ITEMS {
        if item.signal == gmgn_gpui_ui::startup::Signal::PhysicsProbe {
            continue;
        }
        signals.set(item.signal, true);
    }
    assert_eq!(gate.observe(&signals, 0), StartupPhase::Preparing);
    let phase = gate.observe(&signals, 30_000);
    assert_eq!(phase, StartupPhase::Ready, "a preflight miss must not block entry");
    let named = gate.named();
    let physics = named
        .iter()
        .find(|view| view.id == "world.physics")
        .expect("the miss must be named before entry");
    assert_eq!(physics.phase, StepPhase::Unavailable);
    assert!(physics.code.is_some());
}

#[test]
fn the_gate_opens_the_moment_every_signal_is_observed() {
    let mut gate = StartupGate::new();
    let mut signals = StartupSignals::new();
    for item in STARTUP_ITEMS {
        signals.set(item.signal, true);
    }
    // 依赖是**显式声明**的，所以声明顺序里靠前的项在同一次观察里就满足了后面的依赖：
    // 一次观察即可开门，不是"一项一 tick"。
    assert_eq!(gate.observe(&signals, 0), StartupPhase::Ready);
    assert!(gate.failure().is_none());
    for view in gate.steps() {
        assert!(
            matches!(view.phase, StepPhase::Ready | StepPhase::Deferred),
            "{} is {:?} although its signal was observed",
            view.id,
            view.phase
        );
    }
    // 就绪之后，清单里每一项都真的在表里（没有孤儿）。
    for view in gate.steps() {
        assert!(readiness_item(view.id).is_some());
    }
}

// ---------------------------------------------------------------------------
// 字面量扫描器
// ---------------------------------------------------------------------------

/// 把 `#[cfg(test)] mod … { … }` 的**本体**抹白（保留换行与字节长度）。
///
/// **只用字节偏移**：这里以前把"字节位置"和"字符下标"混着用，于是含中文的源码里
/// `from` 会落在当前 marker 之前，`find` 每次都找到同一个 marker——门禁自己死循环。
/// 花括号是 ASCII，所以按字节配平并只把 ASCII 字节换成空格，绝不会切断多字节字符。
fn blank_rust_test_modules(src: &str) -> String {
    const MARKER: &str = "#[cfg(test)]";
    let bytes = src.as_bytes();
    let mut out = bytes.to_vec();
    let mut from = 0usize;
    while from < src.len() {
        let Some(offset) = src[from..].find(MARKER) else { break };
        let start = from + offset;
        let Some(open_rel) = src[start..].find('{') else { break };
        let open = start + open_rel;
        let mut depth = 0i32;
        let mut index = open;
        while index < bytes.len() {
            match bytes[index] {
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                _ => {}
            }
            index += 1;
        }
        let end = (index + 1).min(bytes.len());
        for slot in out.iter_mut().take(end).skip(start) {
            if *slot != b'\n' {
                *slot = b' ';
            }
        }
        from = end.max(start + MARKER.len());
    }
    String::from_utf8(out).expect("blanking replaces ASCII bytes with spaces and cannot split UTF-8")
}

/// 取出 `src` 里的字符串字面量**本体**，带它开始那一行（1-based）。
fn string_literals(src: &str, lang: ScanLang) -> Vec<(usize, String)> {
    let chars: Vec<char> = src.chars().collect();
    let n = chars.len();
    let mut out = Vec::new();
    let mut index = 0usize;
    let mut line = 1usize;
    while index < n {
        let current = chars[index];
        if current == '\n' {
            line += 1;
            index += 1;
            continue;
        }
        if current == '/' && index + 1 < n && chars[index + 1] == '/' {
            while index < n && chars[index] != '\n' {
                index += 1;
            }
            continue;
        }
        if current == '/' && index + 1 < n && chars[index + 1] == '*' {
            let mut depth = 1usize;
            index += 2;
            while index < n && depth > 0 {
                if chars[index] == '\n' {
                    line += 1;
                }
                if !lang.is_rust()
                    && chars[index] == '/'
                    && index + 1 < n
                    && chars[index + 1] == '*'
                {
                    depth += 1;
                    index += 2;
                    continue;
                }
                if chars[index] == '*' && index + 1 < n && chars[index + 1] == '/' {
                    depth -= 1;
                    index += 2;
                    continue;
                }
                index += 1;
            }
            continue;
        }
        // Rust raw strings: r"…" / r#"…"#
        if lang.is_rust() && current == 'r' && index + 1 < n && (chars[index + 1] == '#' || chars[index + 1] == '"') {
            let mut cursor = index + 1;
            let mut hashes = 0usize;
            while cursor < n && chars[cursor] == '#' {
                hashes += 1;
                cursor += 1;
            }
            if cursor < n && chars[cursor] == '"' {
                cursor += 1;
                let start_line = line;
                let start = cursor;
                while cursor < n {
                    if chars[cursor] == '"' {
                        let mut seen = 0usize;
                        let mut probe = cursor + 1;
                        while seen < hashes && probe < n && chars[probe] == '#' {
                            seen += 1;
                            probe += 1;
                        }
                        if seen == hashes {
                            break;
                        }
                    }
                    cursor += 1;
                }
                let body: String = chars[start..cursor.min(n)].iter().collect();
                line += body.chars().filter(|c| *c == '\n').count();
                out.push((start_line, body));
                index = (cursor + 1 + hashes).min(n);
                continue;
            }
        }
        // C# verbatim strings: @"…" ("" is a literal quote)
        if lang == ScanLang::CLike && current == '@' && index + 1 < n && chars[index + 1] == '"' {
            let start_line = line;
            let mut cursor = index + 2;
            let mut body = String::new();
            while cursor < n {
                if chars[cursor] == '"' {
                    if cursor + 1 < n && chars[cursor + 1] == '"' {
                        body.push('"');
                        cursor += 2;
                        continue;
                    }
                    break;
                }
                if chars[cursor] == '\n' {
                    line += 1;
                }
                body.push(chars[cursor]);
                cursor += 1;
            }
            out.push((start_line, body));
            index = cursor + 1;
            continue;
        }
        if current == '"' {
            // Swift / C# multi-line strings and Rust's `"` alike: `"""` runs to the next `"""`.
            if index + 2 < n && chars[index + 1] == '"' && chars[index + 2] == '"' {
                let start_line = line;
                let mut cursor = index + 3;
                let start = cursor;
                while cursor + 2 < n
                    && !(chars[cursor] == '"' && chars[cursor + 1] == '"' && chars[cursor + 2] == '"')
                {
                    cursor += 1;
                }
                let body: String = chars[start..cursor.min(n)].iter().collect();
                line += body.chars().filter(|c| *c == '\n').count();
                out.push((start_line, body));
                index = (cursor + 3).min(n);
                continue;
            }
            let start_line = line;
            let mut cursor = index + 1;
            let mut body = String::new();
            while cursor < n {
                if chars[cursor] == '\\' {
                    if cursor + 1 < n {
                        body.push(chars[cursor + 1]);
                    }
                    cursor += 2;
                    continue;
                }
                if chars[cursor] == '"' {
                    break;
                }
                if chars[cursor] == '\n' {
                    line += 1;
                }
                body.push(chars[cursor]);
                cursor += 1;
            }
            out.push((start_line, body));
            index = cursor + 1;
            continue;
        }
        index += 1;
    }
    out
}
