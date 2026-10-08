// 工具**参数 schema** 的约束键门禁（2026-10-02，纯 CPU、无网络、不启动 app）。
//
// 为什么需要它：宿主校验器 `ResidentDSHOriginalSchemaValidator` **故意不认**它实现不了的
// JSON-Schema 约束键（`minimum` / `maximum` / `pattern` / `format` / `oneOf` …）。只要工具
// 参数 schema 里出现一个，整条 schema 在派发前就被判 `schema_unsupported`，这个工具
// **一次都执行不到** —— 不是"参数被拒"，而是"工具从来没跑"。
//
//   真机 2026-09-28 逐字回执：
//     `Error: 工具原 schema 含宿主校验器不支持的描述，拒绝执行：`
//     `$.wake_after_seconds: 含无法核验的约束键 maximum,minimum`
//
// 真机上 `hold_prop` 已经因为 `layout_revision` 的 `minimum` 连败 7 次；同一形状在
// `update_resident_intent.wake_after_seconds` 上是**潜伏**的（这条通道当前不走校验，
// 所以病没发作，schema 本身仍然是坏的）。本门禁把它按在源头。
//
// 判据**读校验器自己的白名单**：`Agent/ResidentDSHAgentToolBridge.swift` 里的
// `allowedSchemaKeys` 字面量。这里**不手抄**一份键表 —— 白名单放宽或收紧，这条门禁
// 自动跟随，不可能与校验器分叉。
//
// 每次都跑注入自测（只在内存字符串 / 临时副本里改，绝不碰工作树）：
//   · 往 `ResidentLoopTools.swift` 的 `wake_after_seconds` 塞回 `minimum`/`maximum` ⇒ 必须红；
//   · 塞 `exclusiveMinimum`/`pattern`/`format`/`oneOf` ⇒ 必须红；
//   · 塞白名单内的 `minLength` ⇒ 必须**不**红（反向对照，防"凡键皆红"的假门禁）；
//   · 抹掉 `wake_after_seconds` 的范围说明 / 改成别的范围 ⇒ 必须红；
//   · 把实现里的 `delay >= 1, delay <= 86400` 放宽 ⇒ 必须红。
// 注入不红 = 门禁自己失效。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourcesRoot = root.appendingPathComponent("apps/macos/Sources")
let validatorSource = sourcesRoot.appendingPathComponent("GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift")
let loopToolsSource = sourcesRoot.appendingPathComponent("GMGNRadio/Agent/ResidentLoopTools.swift")
let loopSource = sourcesRoot.appendingPathComponent("GMGNRadio/Agent/ResidentAgentLoop.swift")

var checks = 0
var failures = 0
func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: " + label) }
}

func readSource(_ url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
        print("MISSING SOURCE: \(url.path)")
        return nil
    }
    return text
}

guard let validatorText = readSource(validatorSource) else { exit(1) }
guard let loopToolsText = readSource(loopToolsSource) else { exit(1) }
guard let loopText = readSource(loopSource) else { exit(1) }

// ---------------------------------------------------------------------------
// MARK: - 白名单：读校验器自己的那一份
// ---------------------------------------------------------------------------

/// 从校验器源码里取出 `allowedSchemaKeys: Set<String> = [...]` 的字面量。
/// 取不到 ⇒ 门禁失效（不是"没违规"）：返回 nil 让调用方报红。
func parseAllowedSchemaKeys(_ text: String) -> Set<String>? {
    guard let start = text.range(of: "allowedSchemaKeys: Set<String> = [") else { return nil }
    guard let end = text.range(of: "]", range: start.upperBound..<text.endIndex) else { return nil }
    var keys = Set<String>()
    var current: String?
    for character in text[start.upperBound..<end.lowerBound] {
        if character == "\"" {
            if let pending = current { keys.insert(pending); current = nil } else { current = "" }
        } else if current != nil {
            current?.append(character)
        }
    }
    return keys.isEmpty ? nil : keys
}

guard let allowedKeys = parseAllowedSchemaKeys(validatorText) else {
    print("FAIL: 校验器源码里读不到 allowedSchemaKeys 白名单（判据没有第二份，读不到就是门禁失效）")
    exit(1)
}

// ---------------------------------------------------------------------------
// MARK: - 词表：JSON-Schema 的**约束/注解关键字**（判"是不是 schema 约束键"）
// ---------------------------------------------------------------------------

/// 这份词表只回答"这个键是不是 JSON-Schema 的关键字"，不回答"允不允许"。
/// 允许与否**只看校验器白名单**。所以这里加词只会让门禁更严，不会漏。
let jsonSchemaKeywords: Set<String> = [
    "type", "enum", "const",
    "multipleOf", "maximum", "exclusiveMaximum", "minimum", "exclusiveMinimum",
    "maxLength", "minLength", "pattern", "format",
    "items", "additionalItems", "prefixItems", "contains",
    "maxItems", "minItems", "uniqueItems", "maxContains", "minContains",
    "maxProperties", "minProperties",
    "required", "properties", "patternProperties", "additionalProperties",
    "dependencies", "dependentRequired", "dependentSchemas", "propertyNames",
    "unevaluatedItems", "unevaluatedProperties",
    "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
    "$ref", "$defs", "definitions", "$id", "$schema", "$comment", "$anchor",
    "title", "description", "default", "examples",
    "readOnly", "writeOnly", "deprecated",
    "contentEncoding", "contentMediaType", "contentSchema",
]

print("ALLOWED-KEYS(\(allowedKeys.count)): \(allowedKeys.sorted().joined(separator: ","))")

// ---------------------------------------------------------------------------
// MARK: - 扫描：去注释 + 只认 `"key":` 形态
// ---------------------------------------------------------------------------

/// 去掉行注释与块注释，并**逐字符记住"这个字符在字符串字面量里"**：
/// 字符串内容要留着（JSON 的键值都是字符串），但字符串里的方括号/花括号
/// （`\(…)`、示例 JSON、格式串）绝不能参与括号配对。
func lexSource(_ text: String) -> (clean: String, inString: [Bool]) {
    let units = Array(text.utf16)
    var cleanUnits: [UInt16] = []
    var mask: [Bool] = []
    cleanUnits.reserveCapacity(units.count)
    mask.reserveCapacity(units.count)
    var index = 0
    var inString = false
    var escaped = false
    func append(_ unit: UInt16) { cleanUnits.append(unit); mask.append(inString) }
    while index < units.count {
        let unit = units[index]
        let next = index + 1 < units.count ? units[index + 1] : nil
        if inString {
            if escaped { escaped = false; append(unit) }
            else if unit == 0x5C { escaped = true; append(unit) }
            else if unit == 0x22 { append(unit); inString = false }
            else { append(unit) }
            index += 1
            continue
        }
        if unit == 0x22 { append(unit); inString = true; index += 1; continue }
        if unit == 0x2F, next == 0x2F {
            while index < units.count, units[index] != 0x0A { index += 1 }
            continue
        }
        if unit == 0x2F, next == 0x2A {
            index += 2
            while index + 1 < units.count, !(units[index] == 0x2A && units[index + 1] == 0x2F) { index += 1 }
            index = min(index + 2, units.count)
            continue
        }
        append(unit)
        index += 1
    }
    return (String(decoding: cleanUnits, as: UTF16.self), mask)
}

let keyRegex = try! NSRegularExpression(pattern: "\"([^\"]{1,40})\"\\s*:")
/// "这里是个 schema 字面量"的证据：附近有 JSON-Schema 的 `type` 及其取值。
/// 只看 `"type": "object"`（工具 schema 顶层）或 `"type": "string"/…`（逐参数子 schema）——
/// 工具**回执**里的 `"type": "search"` 这种普通字段不算证据。
let schemaTypeRegex = try! NSRegularExpression(
    pattern: "\"type\"\\s*:\\s*(\"(string|number|integer|boolean|object|array|null)\"|\\[)")

/// 命中的都是 `"键":` 形态、键属于 JSON-Schema 词表、不在校验器白名单里，
/// 而且**真的落在 schema 字面量里**（工具 schema 里嵌着工具回执，回执里的同名字段
/// 不是 schema —— 例如 `search_wish_reference_images` 回执里的 `"title"`）。
func constraintKeyHits(in text: String, allowed: Set<String>) -> [(line: Int, key: String)] {
    let lexed = lexSource(text)
    let clean = lexed.clean
    let mask = lexed.inString
    let ns = clean as NSString

    // 括号配对：只在**字符串外**计数，且**只认 `[` / `]`** —— Swift 里的工具 schema
    // 字面量一律是 `[ ... ]`（字典/数组字面量），`{ ... }` 是代码块（函数/类型体），
    // 把代码块当成 schema 会让"类体里另有 inputSchema"误伤回执里的普通字段。
    // 偏移是 UTF-16，与 NSRegularExpression 的 range 同一坐标系。
    var stack: [Int] = []
    var pairs: [(open: Int, close: Int)] = []
    for (index, unit) in clean.utf16.enumerated() {
        if index < mask.count, mask[index] { continue }
        if unit == 0x5B {
            stack.append(index)
        } else if unit == 0x5D {
            if let open = stack.popLast() { pairs.append((open, index)) }
        }
    }
    var evidenceCache: [Int: Bool] = [:]
    func isSchemaLiteral(open: Int, close: Int) -> Bool {
        if let cached = evidenceCache[open] { return cached }
        let region = ns.substring(with: NSRange(location: open, length: close - open + 1))
        let found = schemaTypeRegex.firstMatch(
            in: region, range: NSRange(location: 0, length: (region as NSString).length)) != nil
        evidenceCache[open] = found
        return found
    }

    var hits: [(Int, String)] = []
    for match in keyRegex.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
        let key = ns.substring(with: match.range(at: 1))
        guard jsonSchemaKeywords.contains(key), !allowed.contains(key) else { continue }
        let location = match.range.location
        // 从最内层往外最多看 8 层括号：`properties` 里的裸约束键靠父级 inputSchema 的
        // `"type": "object"` 认出来；回执字面量往上找不到 schema 证据，就不算。
        let enclosing = pairs
            .filter { $0.open < location && location < $0.close }
            .sorted { $0.open > $1.open }
            .prefix(8)
        guard enclosing.contains(where: { isSchemaLiteral(open: $0.open, close: $0.close) }) else { continue }
        let prefix = ns.substring(to: location)
        hits.append((prefix.filter { $0 == "\n" }.count + 1, key))
    }
    return hits
}

// ---------------------------------------------------------------------------
// MARK: - 扫描域：所有声明/产出**工具参数 schema** 的生产源码
// ---------------------------------------------------------------------------

/// 扫描域**机械派生**（不挑文件、不写白名单）：凡是出现这些标记的文件都在域内 ——
/// `inputSchema`（工具 schema 容器）、`providerTools` / `additionalToolSchemas`
/// （provider 工具清单）、`"parameters"`（function-calling 信封）。
/// 域外的文件（例如把 `format` 当 HTTP 查询参数的文件）不参与判定。
let schemaMarkers = ["inputSchema", "providerTools", "additionalToolSchemas", "\"parameters\""]

func schemaSourceURLs(under root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var urls: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        if schemaMarkers.contains(where: { text.contains($0) }) { urls.append(url) }
    }
    return urls.sorted { $0.path < $1.path }
}

let schemaSources = schemaSourceURLs(under: sourcesRoot)
check(schemaSources.count >= 8, "工具 schema 扫描域不该只有 \(schemaSources.count) 个文件（域派生坏了就是漏检）")

/// 覆盖闸：这几处是**已知**要覆盖的 schema 形状（静态清单 / 逐参数拼装 / 静态 builder /
/// function-calling 信封 / 宿主透传）。它们是"域不许静默缩水"的哨兵，不是键的白名单 —— 
/// 文件改名/搬走会红，但红的是**覆盖**，不是判据。域里多出来的文件照样扫。
let requiredCoverage = [
    "Agent/ResidentLoopTools.swift",
    "Agent/ResidentPropToolBridge.swift",
    "Agent/ResidentWishMachineTools.swift",
    "Agent/ResidentWishReferenceTools.swift",
    "Agent/ResidentVisionTools.swift",
    "Agent/ResidentMusicToolBridge.swift",
    "Agent/ResidentDSHHostToolsBridge.swift",
    "Screen/ResidentScreenTools.swift",
    "Agent/DJAgentToolDispatcher.swift",
    "Agent/WorldAgentToolContract.swift",
]
for relative in requiredCoverage {
    check(schemaSources.contains { $0.path.hasSuffix(relative) },
          "扫描域漏了工具 schema 出没处：\(relative)")
}
print("SCANNED(\(schemaSources.count)): " + schemaSources.map {
    $0.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
}.joined(separator: ","))

// ---------------------------------------------------------------------------
// MARK: - 断言 1：所有工具参数 schema 都不含白名单外的约束键
// ---------------------------------------------------------------------------

var violations: [String] = []
for url in schemaSources {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
    let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
    for hit in constraintKeyHits(in: text, allowed: allowedKeys) {
        violations.append("\(relative):\(hit.line) \(hit.key)")
    }
}
print("EXTERNAL-KEY-HITS(\(violations.count)): " + (violations.isEmpty ? "none" : violations.joined(separator: " | ")))
check(violations.isEmpty,
      "工具参数 schema 里出现宿主校验器不认的约束键（整条 schema 会被判 schema_unsupported，工具一次都跑不到）：\(violations.joined(separator: " | "))")

// 注入自测：只在内存里改字符串，绝不写工作树。
let wakeLineSignature = "\"wake_after_seconds\": [\"type\": \"number\","
func injecting(_ key: String, into text: String) -> String {
    text.replacingOccurrences(of: wakeLineSignature,
                              with: wakeLineSignature + " \"\(key)\": 1,")
}
let injectionPointFound = loopToolsText.contains(wakeLineSignature)
check(injectionPointFound, "注入点（wake_after_seconds 的 schema 行）找不到了，注入自测失去意义")
if injectionPointFound {
    for key in ["minimum", "maximum", "exclusiveMinimum", "pattern", "format", "oneOf", "anyOf", "not", "if", "then", "const", "uniqueItems", "multipleOf", "$ref", "title", "default"] {
        let hits = constraintKeyHits(in: injecting(key, into: loopToolsText), allowed: allowedKeys).map(\.key)
        check(hits.contains(key), "注入 \"\(key)\" 没有被门禁抓到（注入不红 = 门禁失效）")
    }
    // 反向对照：白名单内的键塞进去**不能**红，否则这条门禁只会"凡键皆红"。
    for key in allowedKeys.sorted() {
        let hits = constraintKeyHits(in: injecting(key, into: loopToolsText), allowed: allowedKeys).map(\.key)
        check(!hits.contains(key), "白名单内的 \"\(key)\" 被误判成违规（门禁把合法约束也拒了）")
    }
    print("INJECTION-CAUGHT(A1): 16 个白名单外约束键全部判红；\(allowedKeys.count) 个白名单内键全部不红")
    // 注释里的 `"minimum"` 不是 schema，不能因为注释多一条命中（真机回执文案住在注释里）。
    let baseline = constraintKeyHits(in: loopToolsText, allowed: allowedKeys).map { "\($0.line):\($0.key)" }
    let commented = loopToolsText + "\n// 真机回执：$.wake_after_seconds: 含无法核验的约束键 \"maximum\",\"minimum\"\n"
    let commentedHits = constraintKeyHits(in: commented, allowed: allowedKeys).map { "\($0.line):\($0.key)" }
    check(commentedHits == baseline, "注释里的约束键被当成 schema 违规（注释不该改变判定）")
}

// ---------------------------------------------------------------------------
// MARK: - 断言 2：wake_after_seconds 的范围仍被**实现**拒绝（1 与 86400 的边界照旧）
// ---------------------------------------------------------------------------

/// 范围判据只有一份，住在 `ResidentAgentLoop.updateIntent`：非有限数、小于 1、大于 86400、
/// 或配合了不该带等待的状态 ⇒ `ControlError.invalidWake`。schema 里删掉的 `minimum`/`maximum`
/// 本来就没有在实现里做过判据 —— 删它们是**去掉重复且无效的那一份**，不是放宽。
func wakeBoundsHold(_ sourceText: String) -> Bool {
    guard let start = sourceText.range(of: "func updateIntent") else { return false }
    let window = String(sourceText[start.lowerBound...].prefix(4000))
    func has(_ pattern: String) -> Bool {
        window.range(of: pattern, options: .regularExpression) != nil
    }
    return has("delay\\.isFinite")
        && has("delay\\s*>=\\s*1(?:\\.0)?\\b")
        && has("delay\\s*<=\\s*86400(?:\\.0)?\\b")
        && has("status\\s*==\\s*\\.active\\s*\\|\\|\\s*status\\s*==\\s*\\.waitingEvent")
        && has("throw\\s+ControlError\\.invalidWake")
        && sourceText.contains("唤醒时间需为 1—86400 秒")
}

check(wakeBoundsHold(loopText), "实现里的等待范围判据（1 与 86400 的边界 / 状态门 / invalidWake）不再成立")
if wakeBoundsHold(loopText) {
    let widened = loopText.replacingOccurrences(of: "delay.isFinite, delay >= 1, delay <= 86400,",
                                                with: "delay.isFinite, delay >= 0, delay <= 172800,")
    check(widened != loopText && !wakeBoundsHold(widened), "把实现放宽成 0…172800 没有被抓到（注入不红 = 门禁失效）")
    let droppedFinite = loopText.replacingOccurrences(of: "delay.isFinite, ", with: "")
    check(!wakeBoundsHold(droppedFinite), "去掉有限数判据没有被抓到（注入不红 = 门禁失效）")
    let droppedStatus = loopText.replacingOccurrences(of: "status == .active || status == .waitingEvent", with: "true")
    check(!wakeBoundsHold(droppedStatus), "去掉状态门没有被抓到（注入不红 = 门禁失效）")
    print("INJECTION-CAUGHT(A2-text): 放宽到 0…172800 / 去掉有限数判据 / 去掉状态门 三种改写都判红")
}

// 工具通道必须**原样**把秒数交给实现，不许在这里夹一个 clamp（夹了就等于第二份判据）。
if let start = loopToolsText.range(of: "if let rawDelay = arguments[\"wake_after_seconds\"]") {
    let window = String(loopToolsText[start.lowerBound...].prefix(600))
    check(window.contains("delay = number.doubleValue") && !window.contains("delay = min(") && !window.contains("delay = max("),
          "update_resident_intent 没有把秒数原样交给实现（或偷偷加了 clamp）")
}

// ---------------------------------------------------------------------------
// MARK: - 断言 3：描述里说清了允许范围与会被拒
// ---------------------------------------------------------------------------

func wakeSchemaEntry(in text: String) -> String? {
    guard let range = text.range(of: "\"wake_after_seconds\"") else { return nil }
    let rest = text[range.lowerBound...]
    guard let end = rest.firstIndex(of: "\n") else { return nil }
    return String(rest[..<end])
}

/// 说明必须同时给出：范围（1 到 86400 的写法）、以及"会被拒绝"这件事。
/// 它是 agent 唯一能读到的范围来源 —— 真机 2026-09-28 那条回执的教训。
func wakeEntryExplainsRange(_ entry: String) -> Bool {
    entry.contains("\"description\"")
        && entry.range(of: "1\\s*[–\\-—~至到]\\s*86400", options: .regularExpression) != nil
        && entry.contains("拒绝")
}

if let entry = wakeSchemaEntry(in: loopToolsText) {
    check(wakeEntryExplainsRange(entry), "wake_after_seconds 的 schema 没写清允许范围（1–86400）与会被拒：\(entry)")
    check(!entry.contains("\"minimum\"") && !entry.contains("\"maximum\""),
          "wake_after_seconds 的 schema 里还留着 minimum/maximum：\(entry)")
    // 注入：抹掉说明 / 改掉范围 / 抽掉"拒绝" ⇒ 必须红。
    let withoutDescription = entry.replacingOccurrences(of: "\"description\"\\s*:\\s*\"[^\"]*\"",
                                                        with: "", options: .regularExpression)
    check(withoutDescription != entry && !wakeEntryExplainsRange(withoutDescription),
          "抹掉范围说明没有被抓到（注入不红 = 门禁失效）")
    let wrongRange = entry.replacingOccurrences(of: "86400", with: "172800")
    check(wrongRange != entry && !wakeEntryExplainsRange(wrongRange),
          "把说明里的范围改成 1–172800 没有被抓到（注入不红 = 门禁失效）")
    let withoutRejection = entry.replacingOccurrences(of: "拒绝", with: "接受")
    check(!wakeEntryExplainsRange(withoutRejection),
          "抽掉说明里的「会被拒绝」没有被抓到（注入不红 = 门禁失效）")
    print("INJECTION-CAUGHT(A3): 抹掉范围说明 / 改成 1–172800 / 抽掉「会被拒绝」三种改写都判红")
} else {
    check(false, "ResidentLoopTools 里找不到 wake_after_seconds 的 schema 行")
}

// ---------------------------------------------------------------------------
// MARK: - 断言 2b：把边界**跑起来**（编译真实现，纯 CPU）
// ---------------------------------------------------------------------------

let agentDir = sourcesRoot.appendingPathComponent("GMGNRadio/Agent")
let probeMain = #"""
import Foundation

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: " + label) }
}
@MainActor func settle() async { for _ in 0..<30 { await Task.yield() } }

@MainActor final class WakeProbe {
    var runID: UUID?
    var observations: [(String, Bool)] = []
    func probe(runID: UUID, loop: ResidentAgentLoop) {
        self.runID = runID
        func attempt(_ label: String, _ seconds: Double?, _ status: ResidentAgentLoop.IntentStatus) {
            do {
                try loop.updateIntent(summary: "等待范围边界探针", status: status,
                                      wakeAfterSeconds: seconds, runID: runID)
                observations.append((label, true))
            } catch {
                observations.append((label, false))
            }
        }
        attempt("wake=1", 1, .active)
        attempt("wake=86400", 86400, .active)
        attempt("wake=0.999999", 0.999999, .active)
        attempt("wake=86400.000001", 86400.000001, .active)
        attempt("wake=0", 0, .active)
        attempt("wake=nan", Double.nan, .active)
        attempt("wake=inf", Double.infinity, .active)
        attempt("wake=-1", -1, .active)
        attempt("wake=60@waiting_event", 60, .waitingEvent)
        attempt("wake=60@waiting_user", 60, .waitingUser)
        attempt("wake=60@completed", 60, .completed)
        attempt("wake=nil@completed", nil, .completed)
        attempt("wake=86400@waiting_event", 86400, .waitingEvent)

        // 工具通道：同一条判据，回执是 isError，而不是被 schema 挡在门外。
        let lease = ResidentLoopTools(loop: loop, runID: runID)
        let toolLow = lease.handle(name: "update_resident_intent",
            argumentsJSON: Data("{\"summary\":\"边界探针\",\"status\":\"active\",\"wake_after_seconds\":0.5}".utf8))
        observations.append(("tool wake=0.5 rejected", !toolLow.isError))
        let toolHigh = lease.handle(name: "update_resident_intent",
            argumentsJSON: Data("{\"summary\":\"边界探针\",\"status\":\"active\",\"wake_after_seconds\":86400.001}".utf8))
        observations.append(("tool wake=86400.001 rejected", !toolHigh.isError))
        let toolEdgeLow = lease.handle(name: "update_resident_intent",
            argumentsJSON: Data("{\"summary\":\"边界探针\",\"status\":\"active\",\"wake_after_seconds\":1}".utf8))
        observations.append(("tool wake=1 accepted", !toolEdgeLow.isError))
        let toolEdgeHigh = lease.handle(name: "update_resident_intent",
            argumentsJSON: Data("{\"summary\":\"边界探针\",\"status\":\"active\",\"wake_after_seconds\":86400}".utf8))
        observations.append(("tool wake=86400 accepted", !toolEdgeHigh.isError))
        // schema 里没有范围键之后，工具仍然收得到这个参数（删的是校验器不认的键，不是参数）。
        let schema = ResidentLoopTools.schemas.first { ($0["name"] as? String) == "update_resident_intent" }
        let properties = (schema?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        check(properties?["wake_after_seconds"] != nil, "wake_after_seconds 参数仍在 schema 的 properties 里")
    }
}

@MainActor final class LoopBox { var loop: ResidentAgentLoop! }

@main
struct WakeBoundaryChecks {
    @MainActor static func main() async {
        let probe = WakeProbe()
        // 循环要在自己的 run 闭包里被引用：过 `LoopBox` 持有，避免"捕获后再赋值"。
        let box = LoopBox()
        box.loop = ResidentAgentLoop(now: { Date(timeIntervalSince1970: 1000) },
            configuration: .init(minimumWakeInterval: 10, backgroundTurnsPerHour: 3),
            run: { input in
                probe.probe(runID: input.runID, loop: box.loop)
                return ""
            })
        box.loop.receiveUserMessage("检查等待范围的边界"); await settle()

        let accepted = Set(["wake=1", "wake=86400", "wake=60@waiting_event", "wake=nil@completed",
                            "wake=86400@waiting_event", "tool wake=1 accepted", "tool wake=86400 accepted"])
        let rejected = Set(["wake=0.999999", "wake=86400.000001", "wake=0", "wake=nan", "wake=inf",
                            "wake=-1", "wake=60@waiting_user", "wake=60@completed",
                            "tool wake=0.5 rejected", "tool wake=86400.001 rejected"])
        check(probe.runID != nil, "边界探针真的在居民回合里跑起来了")
        for (label, ok) in probe.observations {
            if accepted.contains(label) {
                check(ok, "边界必须被接受却没有：\(label)")
            } else if rejected.contains(label) {
                check(!ok, "越界/状态不符必须被拒绝却没有：\(label)")
            } else {
                check(false, "探针结果 \(label) 不在期望表里")
            }
        }
        check(probe.observations.count == accepted.count + rejected.count,
              "边界探针条数不对：\(probe.observations.count)")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) wake boundary runtime checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-schema-keys-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let probeURL = temporary.appendingPathComponent("WakeBoundaryChecks.swift")
try probeMain.write(to: probeURL, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("wake-boundary-checks")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
let compiledSources = ["ResidentSteeringDelivery", "ResidentAgentLoop", "ResidentMemoryStore",
                       "ResidentStateClient", "ResidentLoopTools"]
    .map { agentDir.appendingPathComponent("\($0).swift").path }
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library"]
    + compiledSources + ["apps/macos/Sources/GMGNRadio/Presence/RustResidentSchedulerClient.swift", probeURL.path, "-o", executable.path]
do {
    try compiler.run()
    compiler.waitUntilExit()
} catch {
    check(false, "边界探针编译失败：\(error)")
}
if compiler.terminationStatus == 0 {
    let probe = Process()
    probe.executableURL = executable
    let pipe = Pipe()
    probe.standardOutput = pipe
    probe.standardError = pipe
    do {
        try probe.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("FAIL") { print(line) }
        check(probe.terminationStatus == 0, "wake_after_seconds 的运行期边界探针报红（见上面的 FAIL）")
        if let summary = text.split(separator: "\n").last(where: { $0.hasPrefix("PASS") || $0.hasPrefix("FAIL") }) {
            print("RUNTIME-BOUNDARY: \(summary)")
        }
    } catch {
        check(false, "边界探针无法运行：\(error)")
    }
} else {
    check(false, "边界探针编译失败（swiftc 退出码 \(compiler.terminationStatus)）")
}

print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) tool schema key checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
