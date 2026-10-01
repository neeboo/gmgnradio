// 「长期记忆」是**用户决定不做**的能力 —— 这条门禁把"不做"钉住。
//
// ## 为什么需要它
//
// 2026-10-01 用户拍板「长期记忆不要搞」。在那之前这条线已经走到了：原文层
// （`memory_ingest` / `memory_turn`）整体退役、压缩能力从未接线、界面上还有一句
// "长期记忆暂不可用，等压缩接上后自动恢复"。
//
// 决定不做之后，那句话**必须**撤掉：既然不做，就不该在界面上宣传一个不会有的能力
// （它会让人以为"以后会有"）。但仅仅删掉是不够的 —— "不搞"必须是**被钉住的**，
// 否则下一个人（或下一轮自动续跑）看到那张空表和 `memory.rs`，很容易又把它接回来。
//
// ## 判据
//
// 生产**源码**里不得再出现"会让人以为存在长期记忆能力"的东西：
//
//   * 能力类型的声明：`ResidentLongTermMemoryNoticePolicy`；
//   * **面向用户的**能力文案：`长期记忆暂不可用` / `等压缩接上` / `自动恢复`。
//
// 允许（而且是**必须**允许）的是：**说明"已决定不做"的注释与文档**。所以扫描时
// 先剥掉注释 —— 与 `memory.rs` 里那条原文层判据同一个道理（注释里提到这些名字
// 正是在记录"已移除"）。
//
// ## 负对照（否则判据可能恒真）
//
// 把策略类型接回来 / 把用户文案接回来 ⇒ **必须** FAIL。
//
// 只读生产源码，不启动 app、不碰真机数据、不写任何生产文件。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
func require(_ condition: Bool, _ message: String) { if !condition { fail(message) } }

var checks = 0
func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { fail("\(message) [check #\(checks)]") }
}

// ---------------------------------------------------------------------------
// 扫描器（作用于**任意源码文本**，好让负对照能喂进改造过的副本）
// ---------------------------------------------------------------------------

/// 一条违规：哪个模式、在哪一行。
struct Violation: CustomStringConvertible {
    let pattern: String
    let line: Int
    let text: String
    var description: String { "L\(line) `\(pattern)`: \(text.trimmingCharacters(in: .whitespaces))" }
}

/// 剥掉行注释与 `/* */` 块注释后按行扫描。
///
/// 只剥注释是**够用且安全**的：本仓这几条禁词都出现在 Swift 的字符串字面量或
/// 类型声明里，不会与注释语法纠缠；而"说明已决定不做"的注释必须被放过。
func violations(in source: String, patterns: [String]) -> [Violation] {
    var stripped: [String] = []
    var inBlockComment = false
    for rawLine in source.components(separatedBy: .newlines) {
        var line = rawLine
        if inBlockComment {
            guard let end = line.range(of: "*/") else {
                stripped.append("")
                continue
            }
            line = String(line[end.upperBound...])
            inBlockComment = false
        }
        // 去掉本行里的块注释段（可能有 0 个或多个）
        while let start = line.range(of: "/*") {
            if let end = line.range(of: "*/", range: start.upperBound..<line.endIndex) {
                line = String(line[..<start.lowerBound]) + String(line[end.upperBound...])
            } else {
                line = String(line[..<start.lowerBound])
                inBlockComment = true
                break
            }
        }
        // 去掉行注释
        if let comment = line.range(of: "//") {
            line = String(line[..<comment.lowerBound])
        }
        stripped.append(line)
    }

    var found: [Violation] = []
    for (index, line) in stripped.enumerated() {
        for pattern in patterns where line.contains(pattern) {
            found.append(Violation(pattern: pattern, line: index + 1, text: line))
        }
    }
    return found
}

let bannedPatterns = [
    // 能力类型：把策略接回来本身就说明"又打算做了"。
    "ResidentLongTermMemoryNoticePolicy",
    // 宿主侧那根接线（属性名）。
    "residentLongTermMemoryNotice",
    // 面向用户的能力文案：这几句会让人以为"以后会有"。
    "长期记忆暂不可用",
    "等压缩接上",
    "长期记忆当前暂不可用",
]

// 生产源码（Swift + Rust，只扫源码，不扫文档：文档要留着记录这个决定）
let productionSources = [
    "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift",
    "apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift",
    "apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift",
    "apps/macos/Sources/GMGNRadio/Agent/ResidentConversationMemory.swift",
    "apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryClient.swift",
    "services/gmgn-taskd/src/memory.rs",
]

var allViolations: [Violation] = []
for path in productionSources {
    let url = root.appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        fail("读不到生产源码：\(path)")
    }
    let found = violations(in: source, patterns: bannedPatterns)
    if !found.isEmpty {
        print("  [违规] \(path)")
        for item in found { print("         \(item)") }
    }
    allViolations.append(contentsOf: found)
}
check(allViolations.isEmpty,
      "生产代码里不得出现会让人以为「存在长期记忆能力」的类型或用户文案 —— "
      + "用户已决定不做（2026-10-01）。实测违规 \(allViolations.count) 处（见上）")

// 注释里提到这些名字**不算**违规：那正是在记录"已决定不做"。
let commented = """
// 长期记忆已由用户决定不做：原先有 ResidentLongTermMemoryNoticePolicy，
// 它会说「长期记忆暂不可用，等压缩接上后自动恢复」。保留这段说明供追溯。
func unrelated() {}
"""
check(violations(in: commented, patterns: bannedPatterns).isEmpty,
      "判据不得把注释里的历史记录当成违规（否则删干净以后反而永远红）")

// 文档里出现这些词**必须**允许：计划文档要写明这个决定。
let docLike = """
# 计划
长期记忆：**not planned / 用户决定不做**。P-A 系列不执行。
"""
check(violations(in: docLike, patterns: bannedPatterns).isEmpty,
      "文档/计划里的说明不得被当成违规")

// ---------------------------------------------------------------------------
// 负对照：把能力接回来 ⇒ 必须 FAIL
// ---------------------------------------------------------------------------

// 负对照 1：把策略类型接回来。
let restoredType = """
struct ResidentLongTermMemoryNoticePolicy {
    enum Status { case compactionNotAvailable }
}
"""
check(!violations(in: restoredType, patterns: bannedPatterns).isEmpty,
      "**负对照 1 失败**：把 ResidentLongTermMemoryNoticePolicy 接回来竟然没被抓到")

// 负对照 2：把面向用户的文案接回来。
let restoredCopy = """
showResidentVoiceStatus("长期记忆暂不可用：语义压缩能力还没接上，等压缩接上后自动恢复。")
"""
let copyViolations = violations(in: restoredCopy, patterns: bannedPatterns)
check(!copyViolations.isEmpty,
      "**负对照 2 失败**：把「长期记忆暂不可用」这句用户文案接回来竟然没被抓到")
check(copyViolations.count >= 2,
      "负对照 2 应当同时命中多条禁词（实测 \(copyViolations.count) 条）")

// 负对照 3：接回每轮那一条上屏接线（在真实的 App 源码上做**内存中**手术）。
let appPath = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let appSource = try String(contentsOf: appPath, encoding: .utf8)
let mutated = appSource.replacingOccurrences(
    of: "        synchronizeWishMachinePresentation()\n        return reply",
    with: """
        if let sentence = residentLongTermMemoryNotice.record(written: false) {
            showResidentVoiceStatus(sentence)
        } else {
            showResidentVoiceStatus("长期记忆暂不可用：等压缩接上后自动恢复。")
        }
        synchronizeWishMachinePresentation()
        return reply
        """)
require(mutated != appSource,
        "**负对照 3 失败**：手术没生效（`performResidentTurn` 的返回点形状变了）—— "
        + "请同步更新本门禁，否则这条负对照会静默变成恒真")
check(!violations(in: mutated, patterns: bannedPatterns).isEmpty,
      "**负对照 3 失败**：把每轮那条上屏接线接回 `GMGNRadioApp.swift` 竟然没被抓到")

// ---------------------------------------------------------------------------
// 顺带钉住"不做"的另外两面（防止有人只看类型、不看数据与文档）
// ---------------------------------------------------------------------------

// 数据面：那几张空表**保留但不在计划内**，README 必须写明。
let readme = try String(contentsOf: root.appendingPathComponent("services/gmgn-taskd/README.md"),
                        encoding: .utf8)
check(readme.contains("保留但不在计划内"),
      "README 必须写明那几张记忆表「保留但不在计划内」（否则后人看到空表会以为该接上）")
check(readme.contains("长期记忆") && readme.contains("不做"),
      "README 必须写明「长期记忆已由用户决定不做」")

// memory.rs 里现已 dead 的写入方也要有说明（表留着、写入方不接线）。
let memoryRS = try String(contentsOf: root.appendingPathComponent("services/gmgn-taskd/src/memory.rs"),
                          encoding: .utf8)
check(memoryRS.contains("不做"),
      "`memory.rs` 必须写明长期记忆已决定不做（dead 写入方要留下理由）")

print("PASS: \(checks) 条「长期记忆不做」判据 —— "
      + "生产源码里无能力类型、无面向用户的「暂不可用」文案（注释与文档里的追溯说明放行），"
      + "README 与 memory.rs 写明保留但不在计划内；"
      + "3 个负对照（接回策略类型 / 接回用户文案 / 接回每轮上屏接线）都被抓到")
