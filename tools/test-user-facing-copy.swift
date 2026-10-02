// 用户可见文案门禁：机械扫描**所有用户可见字符串**，命中「内部术语 / key=value /
// UUID / 文件路径 / 省略号堆叠 / 打勾打叉 / 超长」⇒ 红。
//
// 用户 2026-10-02 原话：「所有的提示，所有的错误提示和 warning 都需要简化」。
// 同一句抱怨当天出现过五次（文案长、全是 key-value、别打勾打叉、乱七八糟）。
// 所以这条门禁是**全量**的：它不挑文件、不挑函数，只挑「这句话会不会被用户看到」。
//
// 判据（第 2、3、4 条 + 超长）：
//   TERM   内部术语（DSH / session / runtime / 后端 / 视觉会话 / IPC / 模块名…）
//   KV     `key=value` 形态
//   UUID   裸 UUID
//   PATH   绝对路径 / 带扩展名的内部文件名
//   ELL    省略号堆叠（…）  …，  … 再接一个 …）
//   MARK   打勾打叉（✓ ✗ ✅ ❌ ⚠）
//   UNIT   毫秒数、m²、法向、面积、网格格数这类给工程看的量
//   LONG   单条 > 60 个汉字，或 > 2 句（。！？； 都算句界）
//
// 豁免**必须**写明理由，见 diagnostics（日志出口，自动识别）与 exemptions（逐条列出）。
// 日志行不是「用户可见字符串」：它们只进 `subsystem=ai.gmgn.radio`，界面上一个字都不留。
// 技术细节（退出码、信号、字段名、期望/实际、哪条判据、哪个文件）因此全部住在日志里。
//
// 运行：
//   swift tools/test-user-facing-copy.swift                 # 扫生产源码
//   swift tools/test-user-facing-copy.swift --root <目录>    # 扫另一棵树（注入自测用）
//   swift tools/test-user-facing-copy.swift --list          # 顺带列出全部用户可见字符串
//
// 注入自测（本文件每次都跑）：把一条超长文案 / 一个 UUID / 一个 key=value / 一个勾叉 /
// 一段省略号堆叠 / 一条文件路径塞进一棵临时树里**同一个相对路径**的位置，要求扫描必须红。
// 注入不红 = 门禁自己失效。
import Foundation

// ---------------------------------------------------------------------------
// MARK: - 规则
// ---------------------------------------------------------------------------

/// 内部术语：一律不许出现在用户可见文案里。每一条都对应一个用户看不懂的词。
let bannedTerms: [String] = [
    "DSH", "session", "runtime", "后端", "视觉会话", "IPC",
    "world_records", "layoutReceipts", "objectStates", "sourceWishID",
    "isEnabled", "heldProp", "claimed.", "gmgn-taskd", "gmgn-mcpd", "xcodebuild",
    "revision", "schema", "stopReason", "exitCode", "tool_call", "final JSON",
]

struct Rule {
    let id: String
    let detail: String
}

/// 句界：。！？；都算一句的结束，与「最多一到两句」的口径一致。
func sentenceCount(_ text: String) -> Int {
    text.split(whereSeparator: { "。！？；".contains($0) })
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .count
}

func hanziCount(_ text: String) -> Int {
    text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
}

let kvPattern = try! NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*\\s*=\\s*\\S")
let uuidPattern = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}")
let pathPattern = try! NSRegularExpression(pattern: "(/Users/|/tmp/|/private/|~/|[A-Za-z0-9_]+\\.(swift|json|py|sh|mjs|pcm))")
let unitPattern = try! NSRegularExpression(pattern: "([0-9]+\\s*(ms|毫秒)|m²|平方米|法向|面积|网格格数)")

func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return pattern.firstMatch(in: text, options: [], range: range) != nil
}

/// 一条用户可见文案的违规判定。空数组 = 合规。
func violations(in text: String) -> [Rule] {
    var found: [Rule] = []
    for term in bannedTerms where text.contains(term) {
        found.append(Rule(id: "TERM", detail: "内部术语「\(term)」"))
        break
    }
    if matches(kvPattern, text) { found.append(Rule(id: "KV", detail: "key=value 形态")) }
    if matches(uuidPattern, text) { found.append(Rule(id: "UUID", detail: "裸 UUID")) }
    if matches(pathPattern, text) { found.append(Rule(id: "PATH", detail: "文件路径/内部文件名")) }
    if text.contains("…）") || text.contains("…，") || text.components(separatedBy: "…").count > 2 {
        found.append(Rule(id: "ELL", detail: "省略号堆叠"))
    }
    if text.contains(where: { "✓✗✅❌⚠".contains($0) }) {
        found.append(Rule(id: "MARK", detail: "打勾打叉"))
    }
    if matches(unitPattern, text) { found.append(Rule(id: "UNIT", detail: "工程量（毫秒/面积/法向/格数）")) }
    let hanzi = hanziCount(text)
    let sentences = sentenceCount(text)
    if hanzi > 60 || sentences > 2 {
        found.append(Rule(id: "LONG", detail: "超长（\(hanzi) 个汉字 / \(sentences) 句）"))
    }
    return found
}

// ---------------------------------------------------------------------------
// MARK: - 豁免（每一条都必须有理由）
// ---------------------------------------------------------------------------

/// 日志出口：这里面的字符串**不是**用户可见文案，它们只进 os.log。
/// 技术细节（退出码、信号、字段名、期望/实际、判据、文件）按设计全部住在这里。
/// 判据是**调用名**，不是一个文件白名单 —— 同一个文件里既有日志也有界面文案。
let diagnosticsCallNames: Set<String> = [
    "note", "failure", "emit", "notice", "error", "debug", "info", "warning",
    "trace", "log", "Logger", "os_log", "NSLog", "print",
    "reportJukeboxSilence", // 只写 livingWorldLogger.error，屏上那一行另行判定
]

func isDiagnosticCall(_ name: String) -> Bool {
    let last = name.split(separator: ".").last.map(String.init) ?? name
    if diagnosticsCallNames.contains(last) { return true }
    if last.hasPrefix("note") { return true } // noteSceneInputChain / noteKeyBranch
    // imageChainNote / imageChainFailure / ResidentImageChainLog.note / WishReferenceLog.emit …
    if last.hasSuffix("Note") || last.hasSuffix("Failure") || last.hasSuffix("Log") { return true }
    return false
}

/// 豁免条目。`pathContains` + `literalContains` 同时命中才豁免 —— 逐条，可复查。
struct Exemption {
    let pathContains: String
    let literalContains: String
    let reason: String
}

/// 模型面提示词：发给**模型**的工具说明与系统提示，不上屏、不进居民口播。
/// 它们必须保留字段名（模型要照着产出 `layout_revision` 这样的参数），
/// 所以「无内部术语」这条对它们不成立 —— 但它们也**不是**用户可见文案。
let exemptions: [Exemption] = [
    // 系统提示 / 人格提示：只发给模型。
    Exemption(pathContains: "Agent/AgentConversationService.swift", literalContains: "可通过本轮正式工具清单中声明的空间", reason: "模型系统提示（worldTools 说明），不上屏"),
    Exemption(pathContains: "Agent/AgentConversationService.swift", literalContains: "当前为只读聊天，没有空间动作工具", reason: "模型系统提示（只读模式），不上屏"),
    Exemption(pathContains: "Agent/AgentConversationService.swift", literalContains: "本轮只收到思考过程", reason: "模型纠正提示，不上屏"),
    Exemption(pathContains: "Agent/AgentConversationService.swift", literalContains: "上一次输出格式无效", reason: "模型纠正提示，不上屏"),
    Exemption(pathContains: "Agent/AgentConversationService.swift", literalContains: "这是刚才正式工具的返回数据", reason: "模型回执包装提示，不上屏"),
    Exemption(pathContains: "Agent/ResidentAgentLoop.swift", literalContains: "intentPausedByUser=true", reason: "模型系统提示（暂停语义），不上屏"),
    Exemption(pathContains: "Agent/ResidentAgentLoop.swift", literalContains: "用户已停止此意图", reason: "模型纠正提示（工具参数），不上屏"),
    Exemption(pathContains: "Agent/ResidentDSHConfiguration.swift", literalContains: "这个空间是供你生活、工作和玩耍的居所", reason: "居民人格系统提示，只发模型"),
    Exemption(pathContains: "Agent/ResidentDSHConfiguration.swift", literalContains: "acp-agent.model=", reason: "诊断日志行（模型目录摘要）"),
    Exemption(pathContains: "Agent/ResidentLoopTools.swift", literalContains: "读取居民自身真实状态", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentLoopTools.swift", literalContains: "记录当前意图、计划步骤和推进条件", reason: "模型面工具说明"),
    // 工具说明（模型照着产出参数，必须带字段名）。
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "删除的理由，最多 200 字", reason: "模型面参数说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "挂点（**可省**", reason: "模型面参数说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "布局版本（**必填**）", reason: "模型面参数说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "读取真实已拥有物件", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "按本轮人类摆放或移动委托提交", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "让当前已适配居民拿起", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "微调**当前挂点**上那件道具", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "把当前挂载的道具精确放回", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "为已拥有摆件启用受支持的使用能力模板", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "**永久删除**一件已拥有的生成资产", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentPropToolBridge.swift", literalContains: "layout_revision 必须是**非负整数**", reason: "模型面参数校验说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "尺寸意图，**两种形状二选一**", reason: "模型面参数说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "三轴形状的标签", reason: "模型面参数说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "三轴尺寸（毫米）", reason: "模型面参数说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "旧字段，等价于", reason: "模型面参数说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "用登记图片提交一次异步生成", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "省略 wish_id 可查看", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "只读地读回许愿机", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "仅本轮用户明确要求恢复指定旧许愿委托", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "尺寸给了两遍", reason: "模型面参数校验说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "尺寸给了两种形状", reason: "模型面参数校验说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "size_intent.millimeters 必须与", reason: "模型面参数校验说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "size_intent.source =", reason: "模型面参数校验说明"),
    Exemption(pathContains: "Agent/ResidentWishMachineTools.swift", literalContains: "高（up = ±Y）", reason: "模型面轴标签（契约词），不上屏"),
    Exemption(pathContains: "Agent/ResidentWishReferenceTools.swift", literalContains: "检索公开网页图片作为制作参考", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentWishReferenceTools.swift", literalContains: "把一张公开图片直链安全下载", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentWishReferenceTools.swift", literalContains: "没有找到可用图片", reason: "模型面回执（对模型说明这不是失败）"),
    Exemption(pathContains: "Agent/ResidentVisionTools.swift", literalContains: "expected_world_revision", reason: "模型面参数校验说明与工具说明"),
    Exemption(pathContains: "Agent/ResidentVisionTools.swift", literalContains: "发起请求时调用方已知", reason: "模型面参数说明"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "⇒ axis=", reason: "模型面契约示例"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "上下方向（±Y", reason: "模型面轴定义"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "用户说「1443 x 862 x 302 mm」时", reason: "模型面契约示例"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "size_intent 有两种**形状**", reason: "模型面契约说明"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "旧字段，等价于 axis=", reason: "模型面契约说明"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "尺寸本身畸形", reason: "模型面契约说明"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "服务自报的接受范围", reason: "模型面契约说明"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "用户已经 \\(attempt - 1) 次没有给尺寸", reason: "模型面重问策略提示"),
    Exemption(pathContains: "Agent/DJAgentToolDispatcher.swift", literalContains: "调用当下读取真实播放关系", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/DJAgentToolDispatcher.swift", literalContains: "准备指定歌单中的真实曲目", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/DJAgentToolDispatcher.swift", literalContains: "播放当前选中的歌曲", reason: "模型面工具说明"),
    Exemption(pathContains: "Agent/ResidentDSHAgentToolBridge.swift", literalContains: "仅支持顶层 type=object", reason: "模型面参数校验说明"),
    // 诊断/进度出口：只在日志与 30Hz 内部叙述里出现，不上屏。
    Exemption(pathContains: "App/GMGNRadioApp.swift", literalContains: "这次执行实例已经触发过一次播放尝试", reason: "重复帧去重进度（只进日志）"),
    Exemption(pathContains: "App/GMGNRadioApp.swift", literalContains: "冷队列恢复完成：current=", reason: "恢复进度日志"),
    Exemption(pathContains: "Presence/PropGenerationClient.swift", literalContains: "size_intent 不是合法的三轴尺寸", reason: "解码失败诊断（面向守护进程合同，只进日志）"),
    Exemption(pathContains: "Presence/ResidentVisionCapture.swift", literalContains: "世界状态已重载(期望", reason: "画面判据诊断（只进日志）"),
    Exemption(pathContains: "Agent/ResidentDSHHostToolsBridge.swift", literalContains: "宿主工具 IPC 协议版本不匹配", reason: "通道握手诊断（只进日志）"),
    // 工具协议回执（返回给**模型**的 toolError payload）：告诉模型它的工具定义或参数
    // 哪里不对，模型据此改。这些字段名（schema / JSON 对象）是模型要用的词，不上屏。
    Exemption(pathContains: "Agent/ResidentDSHAgentToolBridge.swift", literalContains: "schema", reason: "工具协议回执（返回给模型），不上屏"),
    Exemption(pathContains: "Agent/ResidentDSHHostToolsBridge.swift", literalContains: "schema", reason: "工具协议回执（返回给模型），不上屏"),
    Exemption(pathContains: "Agent/ResidentClaudeToolBridge.swift", literalContains: "schema", reason: "工具协议回执（返回给模型），不上屏"),
    Exemption(pathContains: "Agent/WishMachineContract.swift", literalContains: "参数不符合工具 schema", reason: "工具协议回执码表（返回给模型），不上屏"),
    // 模型面诊断结论：resident 会把结论转成自己的人话，原文不进界面。
    Exemption(pathContains: "Agent/ResidentWishReferenceDiagnosis.swift", literalContains: "没有找到可用图片", reason: "模型面搜索结论（不是失败），不上屏"),
    // 五条腿校验：这些字段只在 livingWorldLogger.notice 拼成一行日志（GMGNRadioApp.swift:3966），不上屏。
    Exemption(pathContains: "Presence/PropAttachment.swift", literalContains: "sha256:", reason: "资产校验诊断（只在 livingWorldLogger.notice 里出现），不上屏"),
    Exemption(pathContains: "Presence/PropAttachment.swift", literalContains: "哈希=未重算", reason: "资产校验诊断（只在 livingWorldLogger.notice 里出现），不上屏"),
    // 场景输入链：14 条诊断行，只进 logger（本次任务明确不许动它们）。
    Exemption(pathContains: "VisualEngine/StageWindowController.swift", literalContains: "consumesPropPointer=", reason: "场景输入链诊断描述（只进 noteSceneInputChain 日志）"),
    // 屏幕标定：用户可见的面板文案**已经**收敛到单一出口 `ScreenPanelCopy`
    // （由 tools/test-resident-tv-look.swift 逐字钉住：不出现 法向/面积/m²/格/ms/key=value）。
    // 这三条是**工程注记**（可复核读数），随标定结果与模型侧快照走，不进面板。
    Exemption(pathContains: "Screen/WorldScreenGeometry.swift", literalContains: "小于 0.04 m² 的阈值", reason: "标定工程注记（可复核读数；面板文案在 ScreenPanelCopy）"),
    Exemption(pathContains: "Screen/WorldScreenInference.swift", literalContains: "由最大平坦面推断", reason: "标定工程注记（可复核读数；面板文案在 ScreenPanelCopy）"),
    Exemption(pathContains: "Screen/WorldScreenInference.swift", literalContains: "判不出板形", reason: "标定工程注记（可复核读数；面板文案在 ScreenPanelCopy）"),
    Exemption(pathContains: "Screen/WorldScreenInference.swift", literalContains: "按它面积较大的", reason: "标定工程注记（可复核读数；面板文案在 ScreenPanelCopy）"),
]

/// 冻结文件：本次**不许碰**（并发线占用）。逐条列出，每次运行都打印，
/// 不许当成「已经合规」—— 它们是欠账，不是豁免。
struct OpenFinding {
    let pathContains: String
    let literalContains: String
    let reason: String
}

/// 2026-10-02 归零：唯一投影 `ResidentOwnershipProjection.swift` 里那三条大字面
/// （`:430` 按 sourceWishID 认到所属许愿 / `:491` 世界回执 claimed.<uuid> / `:493`
/// layoutReceipts…objectStates…）已经就地改成一句人话，本清单因此空了。
///
/// 「唯一投影不许长第二套状态推导」那条门禁没有消失，只是**不再钉整文件哈希**：
/// 它现在钉状态语义（类型 / 函数签名 / 五种对外状态的集合 / 动作派生的集合 /
/// 不许有 `Codable` / 不许有 `init(rawValue:)`），文案字符串逐条放开。
/// 见 `tools/test-ownership-list-plain-interface.swift` 判据 5。清单为空 = 没有欠账。
let openFindings: [OpenFinding] = []

// ---------------------------------------------------------------------------
// MARK: - 词法扫描（注释感知、调用链感知）
// ---------------------------------------------------------------------------

struct Literal {
    let path: String
    let line: Int
    let text: String
    let calls: [String]
}

/// 把注释替换成等长空白，保留偏移与换行。
func stripComments(_ source: [Character]) -> [Character] {
    var out = source
    var i = 0
    let n = source.count
    while i < n {
        let c = source[i]
        if c == "/", i + 1 < n, source[i + 1] == "/" {
            var j = i
            while j < n, source[j] != "\n" { out[j] = " "; j += 1 }
            i = j
        } else if c == "/", i + 1 < n, source[i + 1] == "*" {
            var j = i + 2
            while j < n, !(source[j] == "*" && j + 1 < n && source[j + 1] == "/") {
                if source[j] != "\n" { out[j] = " " }
                j += 1
            }
            let end = min(n, j + 2)
            while j < end { out[j] = " "; j += 1 }
            i = end
        } else if c == "\"" {
            var j = i + 1
            while j < n {
                if source[j] == "\\" { j += 2; continue }
                if source[j] == "\"" { j += 1; break }
                if source[j] == "\n" { break }
                j += 1
            }
            i = j
        } else {
            i += 1
        }
    }
    return out
}

func isIdentifierChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "_" || c == "." || c == ":"
}

/// 单趟扫描：收集字符串字面量，同时维护「谁套着我」的调用链。
func scanLiterals(path: String, source: String) -> [Literal] {
    let raw = Array(source)
    let clean = stripComments(raw)
    let n = clean.count
    var result: [Literal] = []
    var stack: [(kind: Character, name: String)] = []
    var line = 1
    var i = 0
    while i < n {
        let c = clean[i]
        if c == "\n" { line += 1; i += 1; continue }
        if c == "\"" {
            if i + 2 < n, clean[i + 1] == "\"", clean[i + 2] == "\"" {
                i += 3
                continue
            }
            var j = i + 1
            var text = ""
            while j < n {
                if clean[j] == "\\", j + 1 < n {
                    text.append(clean[j]); text.append(clean[j + 1]); j += 2; continue
                }
                if clean[j] == "\"" { break }
                if clean[j] == "\n" { break }
                text.append(clean[j]); j += 1
            }
            result.append(Literal(path: path, line: line, text: text,
                                  calls: stack.map(\.name).filter { !$0.isEmpty }))
            i = min(n, j + 1)
            continue
        }
        if c == "(" || c == "[" || c == "{" {
            var k = i - 1
            while k >= 0, clean[k] == " " || clean[k] == "\t" || clean[k] == "\n" { k -= 1 }
            let end = k
            while k >= 0, isIdentifierChar(clean[k]) { k -= 1 }
            let name = end > k ? String(clean[(k + 1)...end]) : ""
            stack.append((c, name))
            i += 1
            continue
        }
        if c == ")" || c == "]" || c == "}" {
            if !stack.isEmpty { stack.removeLast() }
            i += 1
            continue
        }
        i += 1
    }
    return result
}

// ---------------------------------------------------------------------------
// MARK: - 扫描一棵树
// ---------------------------------------------------------------------------

struct ScanResult {
    var visible: [Literal] = []      // 判定过的用户可见字符串
    var exempted: [(Literal, String)] = []
    var diagnostics = 0
    var openHits: [(Literal, String)] = []
    var violations: [(Literal, [Rule])] = []
    var files = 0
    var totalLiterals = 0
}

func swiftFiles(under root: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var out: [URL] = []
    for case let url as URL in e where url.pathExtension == "swift" { out.append(url) }
    return out.sorted { $0.path < $1.path }
}

func scan(root: URL) -> ScanResult {
    var r = ScanResult()
    let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
    for file in swiftFiles(under: base) {
        r.files += 1
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let rel = file.path.replacingOccurrences(of: root.path + "/", with: "")
        for literal in scanLiterals(path: rel, source: source) {
            guard literal.text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { continue }
            r.totalLiterals += 1
            if literal.calls.contains(where: isDiagnosticCall) { r.diagnostics += 1; continue }
            if let ex = exemptions.first(where: {
                rel.contains($0.pathContains) && literal.text.contains($0.literalContains)
            }) {
                r.exempted.append((literal, ex.reason))
                continue
            }
            if let open = openFindings.first(where: {
                rel.contains($0.pathContains) && literal.text.contains($0.literalContains)
            }) {
                r.openHits.append((literal, open.reason))
                continue
            }
            r.visible.append(literal)
            let v = violations(in: literal.text)
            if !v.isEmpty { r.violations.append((literal, v)) }
        }
    }
    return r
}

// ---------------------------------------------------------------------------
// MARK: - 注入自测
// ---------------------------------------------------------------------------

/// 把一条超长文案 / 一个 UUID / 一个 key=value 塞进一棵临时树的**同一个相对路径**，
/// 再跑一次真扫描。三种注入都必须被抓到；抓不到就是门禁自己失效。
func injectionSelfTest() -> Bool {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gmgn-copy-inject-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let injected = """
    import Foundation

    enum InjectedCopy {
        static func longOne() -> String {
            "这次生成没有完成，因为远端服务在你提交之后返回了一个无法识别的结果，而且这个结果里既不包含可以重试的原因，也不包含你已经付出的额度是否会被退回的说明，所以请你自己判断现在到底该不该再点一次生成，或者干脆等到明天再看看情况。"
        }
        static func uuidOne() -> String {
            "任务 3f2b9c41-8d7e-4a06-9b1f-2c5ae0d7bb31 没有完成，请稍后重试。"
        }
        static func kvOne(_ code: String) -> String {
            "生成失败：reason=\\(code)，请稍后重试。"
        }
        static func markOne() -> String {
            "✓ 已保存"
        }
        static func ellipsisOne() -> String {
            "已经登记了…，稍后就能用…（还要等一下…）"
        }
        static func pathOne() -> String {
            "读不到 /Users/ghostcorn/dev/gmgnradio/tmp/state.json，请稍后重试。"
        }
    }
    """
    try? injected.write(to: dir.appendingPathComponent("InjectedCopy.swift"), atomically: true, encoding: .utf8)
    let result = scan(root: root)
    let ids = result.violations.flatMap { $0.1.map(\.id) }
    let ok = ids.contains("LONG") && ids.contains("UUID") && ids.contains("KV")
        && ids.contains("MARK") && ids.contains("ELL") && ids.contains("PATH")
    print(ok
        ? "PASS: injection — 超长文案 / UUID / key=value / 打勾 / 省略号堆叠 / 文件路径六种注入都被判红（\(Set(ids).sorted().joined(separator: ","))）"
        : "FAIL: injection — 注入没有被抓全，门禁自己失效了（命中：\(ids.isEmpty ? "无" : Set(ids).sorted().joined(separator: ","))）")
    return ok
}

// ---------------------------------------------------------------------------
// MARK: - 主流程
// ---------------------------------------------------------------------------

let arguments = CommandLine.arguments
var rootPath = FileManager.default.currentDirectoryPath
if let i = arguments.firstIndex(of: "--root"), i + 1 < arguments.count { rootPath = arguments[i + 1] }
let listAll = arguments.contains("--list")

let root = URL(fileURLWithPath: rootPath)
let result = scan(root: root)

print("PASS: 扫描 \(result.files) 个源文件，\(result.totalLiterals) 条中文文案：判定 \(result.visible.count) 条 / 豁免 \(result.exempted.count) 条 / 日志出口 \(result.diagnostics) 条 / 冻结欠账 \(result.openHits.count) 条")
print("PASS: 用户可见文案 \(result.visible.count) 条，违规 \(result.violations.count) 条")

for (literal, rules) in result.violations {
    print("FAIL: \(literal.path):\(literal.line) [\(rules.map(\.id).joined(separator: "+"))] \(rules.map(\.detail).joined(separator: "；")) — \(literal.text.prefix(120))")
}
_ = violations(in: "")
_ = injectionSelfTest()

if listAll {
    for literal in result.visible.sorted(by: { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }) {
        print("COPY \(literal.path):\(literal.line)\t\(hanziCount(literal.text))\t\(literal.text)")
    }
}
for (literal, reason) in result.openHits {
    print("OPEN(frozen): \(literal.path):\(literal.line) — \(reason) — \(literal.text.prefix(80))")
}
if !result.violations.isEmpty {
    print("FAIL: 用户可见文案还有 \(result.violations.count) 条不合规（规则见文件头）")
}
