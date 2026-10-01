// 尺寸意图（`size_intent`）的端到端行为检查。
//
// 这一轮修的是**提交前就说清楚「哪根轴、多少米」**，而不是事后靠界面自动缩放：
// 真机那把剑（2026-10-01「2B 白色长剑（外形摆件）」）按高度归一成了 8.28 m，
// 比 7 × 8 × 3.2 m 的舱室还长 ⇒ 被摆放判定拒绝、退回库存、从房间里消失。
//
// 这里跑的是**真的**那几份实现：真的 `ResidentWishMachineTools`、真的
// `WishMachineCoordinator`、真的 `PropGenerationStore`、真的 `PropTaskDaemonClient`
// —— 对面是一个只认 unix socket 的 Python 替身，它把收到的 `submit` 参数**原样记下来**，
// 于是「线上到底发了什么」可以逐字节断言（而不是读源码猜）。
//
// 每一条断言都对应一种「悄悄变坏」的方式：
//   1. 用户说「一把 1.1 米的剑」⇒ 线上必须是 {axis:longest, meters:1.1, source:user}；
//   2. 「高 35 厘米的咖啡机」⇒ {axis:height, meters:0.35}，而且 height_meters 就是同一个数；
//   3. 旧调用（只给 height_meters）⇒ 线上**根本没有** sizeIntent 这个键（逐字节兼容）；
//   4. 非法/缺失/猜出来的尺寸 ⇒ 可读拒绝，而且**一个提交都没有发出去**；
//   5. 任务的尺寸出处可读（任务行/回执），而且与记录的意图同源。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let required = ["Presence/PropGenerationClient.swift", "Presence/PropGenerationStore.swift",
                "Presence/PropImagePreparation.swift", "Presence/PropTaskDaemonClient.swift",
                "Presence/WishMachineOutputDescriptor.swift", "Presence/WishMachineTaskPresentation.swift",
                "Presence/WishMachineCoordinator.swift", "Agent/WishMachineContract.swift",
                "Agent/ResidentWishMachineTools.swift"]
guard required.allSatisfy({ FileManager.default.fileExists(atPath: sources.appendingPathComponent($0).path) }) else {
    print("FAIL: size-intent sources are missing"); exit(1)
}

// ── 源码级断言：只有 GPU 才能跑到的分支（托盘渲染）与线上编码，用「编同一份源码」来钉 ──
func sourceContains(_ path: String, _ needles: [String], _ message: String) -> Bool {
    guard let text = try? String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8) else {
        print("FAIL: cannot read \(path)"); return false
    }
    guard needles.allSatisfy(text.contains) else {
        print("FAIL: \(message)（缺 \(needles.filter { !text.contains($0) })）"); return false
    }
    return true
}
// 托盘上那件还没登记：有意图就按用户的轴归一，没有才走今天的自动推断。
guard sourceContains("Presence/WishMachineOutputRenderer.swift",
    ["WorldPropSizePolicy.intended(", "intent.axis.policyAxis", "WorldPropSizePolicy.automatic("],
    "许愿机托盘没有按尺寸意图归一（那把剑会照旧被算成 8.28 m）") else { exit(1) }
// 托盘描述符必须带上意图（否则渲染端拿不到「用户说的哪根轴」）。
guard sourceContains("Presence/WishMachineCoordinator.swift",
    ["heightIsGenerationRequest: true, sizeIntent: job.sizeIntent"],
    "托盘描述符没有把尺寸意图带下去") else { exit(1) }
// 线上编码：意图就是契约那三个键，nil 时整块不发。
guard sourceContains("Presence/PropTaskDaemonClient.swift",
    ["sizeIntent: sizeIntent", "let sizeIntent: PropSizeIntent?"],
    "提交没有把尺寸意图编码到线上") else { exit(1) }
// 旧字段与意图的**唯一**判据在同一处：三态判据（可以提交 / 信息不足 / 畸形）与
// 结构化回执共用它，所以不可能各说一套。
guard sourceContains("Agent/ResidentWishMachineTools.swift",
    ["WishMachineContract", "func sizeIntentVerdict", "enum SizeIntentVerdict", "needsInput", "resolveDraft"],
    "许愿工具没有把参数收敛到唯一真相（WishMachineContract）与结构化信息不足上") else { exit(1) }
// 生成入库：意图优先于自动推断，而且落进世界状态的那一份尺寸就是按它算的。
guard sourceContains("App/GMGNRadioApp.swift",
    ["WorldPropSizePolicy.intended(", "sizeIntent: sizeIntent"],
    "生成入库没有把尺寸意图落成世界尺寸（那把剑仍会按高度被算成 8.28 m）") else { exit(1) }

// ── 断言 2：参数与规则**只有一处**定义 ──────────────────────────────────────
// 唯一允许写这些事实的文件是 Agent/WishMachineContract.swift（agent 用只读工具
// `read_wish_machine_contract` 现读）。工具文件与系统提示里再存一份就是旧病复发：
// 三处各一份，改到两份等于没改 —— 真机那把剑就是这么被算成 8.28 m 的。
let parameterFacts = ["axis=longest", "axis=height", "\"longest\"", "\"height\"",
                      "0.01", "先问一句", "不要自己猜", "不要默认按高度"]
func leakedFacts(in text: String) -> [String] { parameterFacts.filter(text.contains) }
func readSource(_ path: String) -> String? {
    try? String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
}
/// 取一个声明的完整正文（括号配对）：断言只钉**那一段**，不在整份大文件上碰运气。
func declarationBody(_ text: String, _ signature: String) -> String? {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    return nil
}
guard let contractSource = readSource("Agent/WishMachineContract.swift") else {
    print("FAIL: 读不到唯一真相文件 Agent/WishMachineContract.swift"); exit(1)
}
// 唯一真相**必须**真的说得出这些事实（否则"只有一处"变成了"一处都没有"）。
guard leakedFacts(in: contractSource).count >= 3 else {
    print("FAIL: WishMachineContract 里没有轴名/范围/例子这些参数事实（实测 \(leakedFacts(in: contractSource))）")
    exit(1)
}
guard let toolSource = readSource("Agent/ResidentWishMachineTools.swift") else {
    print("FAIL: 读不到 Agent/ResidentWishMachineTools.swift"); exit(1)
}
guard leakedFacts(in: toolSource).isEmpty else {
    print("FAIL: 工具 schema/文案里**又**存了一份尺寸参数 \(leakedFacts(in: toolSource))：参数只允许在 WishMachineContract 一处")
    exit(1)
}
guard toolSource.contains("WishMachineContract.pointer") else {
    print("FAIL: 工具说明没有指向唯一真相接口（应引用 WishMachineContract.pointer）"); exit(1)
}
guard let appSource = readSource("App/GMGNRadioApp.swift"),
      let prompt = declarationBody(appSource, "private func wishMachinePromptContext(") else {
    print("FAIL: 找不到 wishMachinePromptContext"); exit(1)
}
guard leakedFacts(in: prompt).isEmpty else {
    print("FAIL: 系统提示里**又**存了一份尺寸参数 \(leakedFacts(in: prompt))：参数只允许在 WishMachineContract 一处")
    exit(1)
}
// 提示词里出现的必须是**指针**（运行时才展开成那句唯一的说明），不是又抄一份参数。
guard prompt.contains("WishMachineContract.pointer") else {
    print("FAIL: 系统提示没有引用唯一真相的指针（WishMachineContract.pointer）"); exit(1)
}
// 只读接口名只允许在唯一真相里定义一次（本脚本独立编译，所以比对字面量）。
guard contractSource.contains("static let toolName = \"read_wish_machine_contract\"") else {
    print("FAIL: 唯一真相没有定义只读接口名 read_wish_machine_contract"); exit(1)
}

let fixture = #"""
import socket,threading,json,os,sys
root,path=sys.argv[1:]
server=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);server.bind(path);os.chmod(path,0o600);server.listen()
lock=threading.RLock();jobs={}
def send(c,value):
 try:
  with lock: c.sendall((json.dumps(value)+'\n').encode())
 except OSError: pass
def record(params):
 with open(root+'/submits.jsonl','a') as f: f.write(json.dumps(params,sort_keys=True)+'\n')
def handle(c,q):
 p=q['params'];m=q['method']
 if m=='configure': r={'configured':True}
 elif m=='snapshot': r={'jobs':[dict(j) for j in jobs.values()],'sequence':len(jobs)}
 elif m=='subscribe': r={'subscribed':True}
 elif m=='submit':
  record(p)
  # 与 Rust `store.submit` 一致：有意图才编码这个键，没有就**整个键都不出现**。
  j={'id':p['id'],'name':p['name'],'endpoint':p['endpoint'],'imagePath':root+'/image.png','imageSHA256':'a'*64,
     'heightMeters':p['heightMeters'],'source':p['source'],'idempotencyKey':p['id'],
     'backendStage':'queued','cancelRequested':False}
  if p.get('sizeIntent') is not None: j['sizeIntent']=p['sizeIntent']
  if p.get('context') is not None: j['context']=p['context']
  jobs[j['id']]=j;r={'job':j}
 else:
  send(c,{'id':q['id'],'error':{'code':'unknown','message':'unsupported'}});return
 send(c,{'id':q['id'],'result':r})
def serve(c):
 try:
  for line in c.makefile('rb'):
   q=json.loads(line);threading.Thread(target=handle,args=(c,q),daemon=True).start()
 except (OSError,ValueError): pass
while True:
 c,_=server.accept();threading.Thread(target=serve,args=(c,),daemon=True).start()
"""#

let program = #"""
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable { let id: UUID; let url: URL; let displayName: String }
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
@MainActor final class ResidentWorldToolSession {
    struct AdditionalTool {
        let name: String; let description: String; let inputSchema: [String: Any]
        let validate: @MainActor ([String: Any]) -> Bool
        let handle: @MainActor (String, Data) async -> RealtimeDJToolResult
    }
}

@main struct Checks {
 @MainActor static func main() async throws {
  var checks = 0, failures: [String] = []
  func check(_ value: Bool, _ label: String) { if value { checks += 1 } else { failures.append(label) } }
  func until(_ label: String, _ predicate: @MainActor () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(6)
      while !predicate() {
          guard Date() < deadline else { failures.append("timeout: " + label); return }
          try await Task.sleep(for: .milliseconds(20))
      }
  }
  func readSubmits(_ root: URL) -> [[String: Any]] {
      guard let text = try? String(contentsOf: root.appendingPathComponent("submits.jsonl"), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").compactMap { line in
          (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
      }
  }
  func parse(_ result: RealtimeDJToolResult) -> [String: Any] {
      (try? JSONSerialization.jsonObject(with: result.resultJSON)) as? [String: Any] ?? [:]
  }
  func arguments(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

  let scratch = URL(fileURLWithPath: "/tmp/gmgn-size-intent-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let socket = scratch.appendingPathComponent("taskd.sock")
  let server = Process()
  server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  server.arguments = ["-u", "-c", try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8), scratch.path, socket.path]
  server.standardOutput = FileHandle.nullDevice
  server.standardError = FileHandle.nullDevice
  try server.run()
  func finish() -> Never {
      server.terminate(); server.waitUntilExit()
      try? FileManager.default.removeItem(at: scratch)
      for failure in failures { print("FAIL: " + failure) }
      guard failures.isEmpty else { exit(1) }
      print("PASS: \(checks) size-intent checks")
      exit(0)
  }
  try await until("fixture socket") { FileManager.default.fileExists(atPath: socket.path) }

  // 一张真的 2×2 PNG：`PropImagePreparation` 与守护进程契约都只认真 PNG。
  let pixels = Data(repeating: 255, count: 16)
  let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let imageURL = scratch.appendingPathComponent("input.png")
  let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, image, nil)
  check(CGImageDestinationFinalize(destination), "fixture PNG")

  let daemon = PropTaskDaemonClient(root: scratch, socketURL: socket, allowsLaunching: false, requestTimeout: 2)
  let store = PropGenerationStore(directory: scratch, daemonClient: daemon)
  try store.configure(endpoint: URL(string: "http://127.0.0.1:8765")!, token: "fixture-secret-only-memory")

  let world = "size-world", resident = "size-resident"
  let coordinator = WishMachineCoordinator(store: store, directory: scratch.appendingPathComponent("wishes"), canClaim: { _ in nil })
  var grant = UUID()
  var attachment = ResidentImageAttachment(id: UUID(), url: imageURL, displayName: "reference.png")
  // 一次人类委托只生成一件：每件物件用自己的授权，否则第二件会被判成超用授权。
  func freshGrant() throws {
      grant = UUID()
      attachment = ResidentImageAttachment(id: UUID(), url: imageURL, displayName: "reference.png")
      try coordinator.authorize(attachments: [attachment], worldID: world, residentScope: resident,
          authorizationID: grant, source: .init(author: "user", license: "internal"))
  }
  func submitTool(capability: WishSizeIntentCapability = .unreadable) -> ResidentWorldToolSession.AdditionalTool {
      ResidentWishMachineTools(coordinator: coordinator, worldID: world, residentScope: resident,
          authorizationID: grant, isCurrent: { true },
          sizeIntentCapability: { capability }).tools.first { $0.name == "submit_wish_generation" }!
  }
  func contractTool(capability: WishSizeIntentCapability = .unreadable) -> ResidentWorldToolSession.AdditionalTool {
      ResidentWishMachineTools(coordinator: coordinator, worldID: world, residentScope: resident,
          authorizationID: grant, isCurrent: { true },
          sizeIntentCapability: { capability },
          serviceFacts: { (true, "fixture") }).tools.first { $0.name == "read_wish_machine_contract" }!
  }
  try freshGrant()
  let submit = submitTool()

  // ── 工具的参数契约：形状对 + **指向唯一真相**，不再自带第二份参数 ──────────
  let schema = submit.inputSchema
  let properties = schema["properties"] as? [String: Any] ?? [:]
  let intentSchema = properties["size_intent"] as? [String: Any] ?? [:]
  let intentProperties = intentSchema["properties"] as? [String: Any] ?? [:]
  check(properties["size_intent"] != nil, "提交工具的 schema 必须带尺寸意图参数")
  check(intentProperties["axis"] != nil && intentProperties["meters"] != nil,
      "尺寸意图必须说得出轴与米数")
  let requiredArguments = Set(schema["required"] as? [String] ?? [])
  check(requiredArguments == ["attachment_id", "name"],
      "尺寸是二选一，不能把旧字段列成必需（实测 \(requiredArguments.sorted())）")
  // 参数事实只能在唯一真相里：schema 自己不许再写轴枚举、轴名、米数范围。
  let ownFacts = ["axis=longest", "axis=height", "\"longest\"", "\"height\"", "0.01"]
  let schemaText = String(decoding: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data(), as: UTF8.self)
      + submit.description
  check(ownFacts.filter { schemaText.contains($0) }.isEmpty,
      "工具 schema/说明里**又**存了一份尺寸参数 \(ownFacts.filter { schemaText.contains($0) })");
  check(schemaText.contains("read_wish_machine_contract"),
      "工具说明必须把 agent 指向唯一真相接口（实测缺 read_wish_machine_contract）")
  // size_intent 内部不许把 axis/meters 列成必需：否则"缺轴"会被 schema 拦成笼统错误，
  // 说不出"缺什么、该问哪一句"，结构化回问就实现不了。
  check((intentSchema["required"] as? [String] ?? []).isEmpty,
      "size_intent 内部不许把 axis/meters 列成必需（缺了要能说得出缺什么）")
  check(properties["pending_id"] != nil, "提交工具必须能接住续办用的 pending_id")

  // ── 断言 1：尺寸缺失 / 轴不明确 ⇒ **结构化**信息不足 ────────────────────────
  // 不抛错（成功通道）、不发提交、不填默认值；并且给出一句问话 + 一个 pending_id。
  try freshGrant()
  let firstAuthority = grant
  let askTool = submitTool()
  let base: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "没说尺寸的剑"]
  check(askTool.validate(base), "缺尺寸必须能走到 handle（否则说不出缺什么）")
  let askResult = await askTool.handle("needs-size", arguments(base))
  let askPayload = parse(askResult)
  check(!askResult.isError, "信息不足必须是**成功**通道（实测 isError=\(askResult.isError)）")
  check(askPayload["code"] as? String == WishMachineContract.Code.needsInput.rawValue,
      "信息不足的码必须是 \(WishMachineContract.Code.needsInput.rawValue)（实测 \(String(describing: askPayload["code"]))）")
  check((askPayload["needs"] as? [String]) == ["size"],
      "必须结构化说出缺什么（实测 \(String(describing: askPayload["needs"]))）")
  check((askPayload["question"] as? String)?.isEmpty == false, "必须给出一句问用户的话")
  check(askPayload["pending_id"] is String, "必须给出续办用的 pending_id")
  check((askPayload["missing"] as? [[String: Any]])?.first?["field"] as? String == "size_intent.axis",
      "missing[].field 必须与 schema 路径逐字一致")
  check(readSubmits(scratch).isEmpty, "信息不足时一个提交都不许发出去（实测 \(readSubmits(scratch).count) 条）")
  let pendingID = askPayload["pending_id"] as! String

  // 轴不明确（给了米数没给轴）同样是信息不足，而且**不填默认轴**。
  try freshGrant()
  let axisAsk = await submitTool().handle("needs-axis",
      arguments(base.merging(["size_intent": ["meters": 0.8] as [String: Any]]) { _, new in new }))
  let axisPayload = parse(axisAsk)
  check(!axisAsk.isError, "缺轴必须是成功通道的信息不足（实测 \(axisPayload)）")
  check((axisPayload["needs"] as? [String]) == ["size_axis"],
      "缺轴必须说缺轴（实测 \(String(describing: axisPayload["needs"]))）")
  check(readSubmits(scratch).isEmpty, "缺轴时一个提交都不许发出去")
  let axisPendingID = axisPayload["pending_id"] as! String

  // ── 断言 4：用户回答后**续上同一次委托**（幂等、不重复生成、不消耗新授权）────
  // 回答发生在**新的一轮**：宿主会开一份新授权。续办必须用草稿里的**原**授权与原
  // requestID，否则就是另一次委托。
  try freshGrant()
  let answerAuthority = grant
  check(answerAuthority != firstAuthority, "第二轮必须真的换了一份授权（否则这条断言没有意义）")
  // 原样回填**草稿**里的 attachment_id/name —— 回答的这一轮换了新授权，本轮附件编号
  // 与原委托不是一回事；回执里的 draft 就是给这个用的。
  let draftEcho = askPayload["draft"] as? [String: Any] ?? [:]
  check(draftEcho["attachment_id"] as? String == base["attachment_id"] as? String,
      "信息不足回执必须原样带回原委托的 attachment_id（实测 \(draftEcho)）")
  let resumeArgs: [String: Any] = ["attachment_id": draftEcho["attachment_id"] as? String ?? "",
      "name": draftEcho["name"] as? String ?? "没说尺寸的剑",
      "pending_id": pendingID, "size_intent": ["axis": "longest", "meters": 0.8] as [String: Any]]
  let resumeTool = submitTool()
  check(resumeTool.validate(resumeArgs), "续办参数必须放行")
  let resumeResult = await resumeTool.handle("needs-size-answer", arguments(resumeArgs))
  let resumePayload = parse(resumeResult)
  check(!resumeResult.isError, "回答之后必须受理（实测 \(resumePayload)）")
  try await until("续办的提交落到替身") { readSubmits(scratch).count == 1 }
  let resumeAuthorization = resumePayload["authorization"] as? [String: Any] ?? [:]
  check(resumeAuthorization["reused"] as? Bool == true
      && resumeAuthorization["source"] as? String == "pending_draft",
      "续办必须复用原委托的授权（实测 \(resumeAuthorization)）")
  check(resumeAuthorization["authority_id"] as? String == firstAuthority.uuidString,
      "必须用**原来**那一份授权，而不是本轮新开的（实测 \(String(describing: resumeAuthorization["authority_id"]))）")
  check(resumeAuthorization["request_id"] as? String == "needs-size",
      "必须复用**原来**那次工具调用的编号（实测 \(String(describing: resumeAuthorization["request_id"]))）")
  let resumedJobs = coordinator.residentJobs(worldID: world, residentScope: resident)
  check(resumedJobs.count == 1 && resumedJobs[0].authorizationID == firstAuthority,
      "只许有**一件**产物，而且挂在原授权上（实测 \(resumedJobs.map(\.authorizationID))）")
  check(!resumedJobs.contains { $0.authorizationID == answerAuthority },
      "回答那一轮的新授权**不许**被消耗")
  check(resumedJobs[0].requestID == "needs-size", "任务的 requestID 必须是原委托那一个")

  // 幂等：同一次委托再调一次（新的 callID，同一个 pending_id）⇒ 回同一个任务，不新建。
  let repeatResult = await resumeTool.handle("needs-size-answer-again", arguments(resumeArgs))
  let repeatPayload = parse(repeatResult)
  check(!repeatResult.isError, "重复续办必须同样受理（实测 \(repeatPayload)）")
  check((repeatPayload["wish_id"] as? String) == (resumePayload["wish_id"] as? String),
      "重复续办必须回**同一个**任务（实测 \(String(describing: repeatPayload["wish_id"])) vs \(String(describing: resumePayload["wish_id"]))）")
  check((repeatPayload["authorization"] as? [String: Any])?["replayed"] as? Bool == true,
      "重复续办必须标成幂等重放")
  try await Task.sleep(for: .milliseconds(200))
  check(readSubmits(scratch).count == 1,
      "重复续办不许产生第二次提交（实测 \(readSubmits(scratch).count) 条）")
  check(coordinator.residentJobs(worldID: world, residentScope: resident).count == 1,
      "重复续办不许长出第二件产物")

  // 说不清是哪一件（pending_id 与 name/附件对不上）⇒ fail-closed：**不猜**，
  // 结构化要求先选定，并且把候选编号列出来。
  let ambiguous = await submitTool().handle("ambiguous",
      arguments(["attachment_id": attachment.id.uuidString, "name": "另一件东西",
                 "pending_id": axisPendingID,
                 "size_intent": ["axis": "longest", "meters": 0.5] as [String: Any]]))
  let ambiguousPayload = parse(ambiguous)
  check(!ambiguous.isError && (ambiguousPayload["needs"] as? [String]) == ["pending_id"],
      "对不上号时必须先选定是哪一件，不许猜（实测 \(ambiguousPayload)）")
  check((ambiguousPayload["missing"] as? [[String: Any]])?.first?["field"] as? String == "pending_id",
      "对不上号时 missing 必须指向 pending_id（实测 \(String(describing: ambiguousPayload["missing"]))）")
  check((ambiguousPayload["options"] as? [String: Any]) != nil, "信息不足回执必须带上可用选项")

  // ── 断言 3：能力读不到 ⇒ 不声称支持；读到了说不收 ⇒ 不发提交（fail-closed）──────
  let readableContract = parse(await contractTool().handle("contract", Data("{}".utf8)))
  let unreadableCapability = readableContract["capability"] as? [String: Any] ?? [:]
  check(unreadableCapability["readable"] as? Bool == false
      && (unreadableCapability["axes"] as? [String])?.isEmpty == true
      && unreadableCapability["applies"] is NSNull,
      "能力读不到时只读接口必须明确 readable=false、axes=[]（读不到 ≠ 支持，实测 \(unreadableCapability)）")
  // 读不到能力**不影响**其它功能：合法尺寸照常提交。
  try freshGrant()
  let unreadableSubmit = await submitTool(capability: .unreadable).handle("unreadable-ok",
      arguments(["attachment_id": attachment.id.uuidString, "name": "读不到能力也要能做",
                 "size_intent": ["axis": "longest", "meters": 0.6] as [String: Any]]))
  check(!parse(unreadableSubmit).isEmpty && !unreadableSubmit.isError,
      "读不到能力不等于不能用（实测 \(parse(unreadableSubmit))）")
  try await until("读不到能力的提交落到替身") { readSubmits(scratch).count >= 2 }
  // 服务声明**只收** height：用户要 longest ⇒ 结构化信息不足，**一个提交都不发**。
  let beforeDeclared = readSubmits(scratch).count
  try freshGrant()
  let narrow = WishSizeIntentCapability.declared(axes: ["height"], minimumMeters: 0.2,
      maximumMeters: 0.8, applies: "echo")
  let unsupported = await submitTool(capability: narrow).handle("axis-not-declared",
      arguments(["attachment_id": attachment.id.uuidString, "name": "服务不收最长边",
                 "size_intent": ["axis": "longest", "meters": 0.5] as [String: Any]]))
  let unsupportedPayload = parse(unsupported)
  check(!unsupported.isError
      && unsupportedPayload["reason"] as? String == WishMachineContract.NeedReason.axisNotDeclared.rawValue
      && unsupportedPayload["unsupported_axis"] as? String == "longest"
      && (unsupportedPayload["service_declared_axes"] as? [String]) == ["height"],
      "轴不被服务声明时必须是结构化信息不足并带上服务的轴（实测 \(unsupportedPayload)）")
  // 声明范围更窄：越界同样是结构化信息不足，**不夹取**。
  let narrowRange = await submitTool(capability: narrow).handle("meters-out-of-declared-range",
      arguments(["attachment_id": attachment.id.uuidString, "name": "超出服务范围",
                 "size_intent": ["axis": "height", "meters": 1.5] as [String: Any]]))
  check(!narrowRange.isError
      && (parse(narrowRange)["reason"] as? String) == WishMachineContract.NeedReason.metersOutOfRange.rawValue,
      "超出服务声明的米数范围必须结构化信息不足（实测 \(parse(narrowRange))）")
  try await Task.sleep(for: .milliseconds(200))
  check(readSubmits(scratch).count == beforeDeclared,
      "轴/范围不被服务接受时**一个提交都不许发**（实测 \(readSubmits(scratch).count - beforeDeclared) 条新增）")

  // ── 畸形输入仍然是**错误**（不伪装成"再问一句"）────────────────────────────
  let malformed: [(String, [String: Any], String)] = [
      ("轴名非法", base.merging(["size_intent": ["axis": "width", "meters": 1.1] as [String: Any]]) { _, new in new }, "longest"),
      ("米数越界", base.merging(["size_intent": ["axis": "longest", "meters": 9] as [String: Any]]) { _, new in new }, "0.01—3"),
      ("出处是猜的", base.merging(["size_intent": ["axis": "longest", "meters": 1.1, "source": "default"] as [String: Any]]) { _, new in new }, "先问"),
      ("尺寸给了两遍", base.merging(["height_meters": 1.1, "size_intent": ["axis": "height", "meters": 1.1] as [String: Any]]) { _, new in new }, "只能给一个"),
  ]
  for (label, args, needle) in malformed {
      let result = await submitTool().handle("invalid-" + label, arguments(args))
      let payload = parse(result)
      check(result.isError && payload["code"] as? String == WishMachineContract.Code.invalidSizeIntent.rawValue,
          "\(label)：必须是 \(WishMachineContract.Code.invalidSizeIntent.rawValue)（实测 \(String(describing: payload["code"]))）")
      check((payload["message"] as? String)?.contains(needle) == true,
          "\(label)：原因必须可读且提到 \(needle)（实测 \(String(describing: payload["message"]))）")
  }
  try await Task.sleep(for: .milliseconds(200))
  check(readSubmits(scratch).count == beforeDeclared, "畸形尺寸一个提交都不许发出去")
  let axisPending = coordinator.pendingDrafts(worldID: world, residentScope: resident)
  check(axisPending.contains { $0.id.uuidString == axisPendingID },
      "缺轴的草稿必须落盘（续办要用它）")

  // ── 「一把 1.1 米的剑」：线上必须说清是最长边 1.1 米 ──────────────────────
  // 上面已经有过成功的提交，所以这里的序号一律相对基线，不写死 1/2/3。
  let baseline = readSubmits(scratch).count
  try freshGrant()
  let swordTool = submitTool()
  let sword: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "2B 白色长剑",
                              "size_intent": ["axis": "longest", "meters": 1.1, "source": "user"] as [String: Any]]
  check(swordTool.validate(sword), "合法的尺寸意图必须放行")
  let swordResult = await swordTool.handle("sword", arguments(sword))
  check(!swordResult.isError, "最长边意图必须受理（实测 \(parse(swordResult))）")
  try await until("剑的提交落到替身") { readSubmits(scratch).count == baseline + 1 }
  let swordWire = readSubmits(scratch)[baseline]
  let swordIntent = swordWire["sizeIntent"] as? [String: Any] ?? [:]
  check(swordWire["heightMeters"] as? Double == 1.1,
      "生成请求的数字必须与用户说的一致（实测 \(String(describing: swordWire["heightMeters"]))）")
  check(swordIntent["axis"] as? String == "longest" && swordIntent["meters"] as? Double == 1.1,
      "线上必须是 {axis:longest, meters:1.1}，而不是按高度（实测 \(swordIntent)）")
  check(swordIntent["source"] as? String == "user", "出处必须是 user（实测 \(String(describing: swordIntent["source"]))）")
  let swordJob = coordinator.residentJobs(worldID: world, residentScope: resident).first { $0.name == "2B 白色长剑" }!
  check(swordJob.sizeIntent?.axis == .longest && swordJob.sizeIntent?.meters == 1.1,
      "意图必须随任务持久化（重放与托盘预览都读它）")
  check(swordJob.sizeIntentLine?.contains("最长边") == true && swordJob.sizeIntentLine?.contains("1.10") == true,
      "任务行必须说得出这个尺寸是怎么定的（实测 \(String(describing: swordJob.sizeIntentLine))）")

  // ── 「高 35 厘米的咖啡机」：老的按高度语义仍然表达得出来 ──────────────────
  try freshGrant()
  let machineTool = submitTool()
  let machine: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "咖啡机",
                                "size_intent": ["axis": "height", "meters": 0.35] as [String: Any]]
  check(machineTool.validate(machine), "按高度的意图必须放行")
  let machineResult = await machineTool.handle("machine", arguments(machine))
  check(!machineResult.isError, "高度意图必须受理（实测 \(parse(machineResult))）")
  try await until("咖啡机的提交落到替身") { readSubmits(scratch).count == baseline + 2 }
  let machineWire = readSubmits(scratch)[baseline + 1]
  let machineIntent = machineWire["sizeIntent"] as? [String: Any] ?? [:]
  check(machineWire["heightMeters"] as? Double == 0.35 && machineIntent["axis"] as? String == "height",
      "按高度的意图：height_meters 与 meters 必须是同一个数（实测 \(String(describing: machineWire["heightMeters"])) / \(machineIntent)）")
  check(machineIntent["source"] as? String == "user", "缺省出处就是 user（用户说的那一个）")

  // ── 旧调用（只有 height_meters）：线上**根本没有** sizeIntent 这个键 ──────
  try freshGrant()
  let legacyTool = submitTool()
  let legacy: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "旧调用斧头", "height_meters": 0.42]
  check(legacyTool.validate(legacy), "旧调用必须继续可用（兼容）")
  let legacyResult = await legacyTool.handle("legacy", arguments(legacy))
  check(!legacyResult.isError, "旧调用必须受理（实测 \(parse(legacyResult))）")
  try await until("旧调用落到替身") { readSubmits(scratch).count == baseline + 3 }
  let legacyWire = readSubmits(scratch)[baseline + 2]
  check(!legacyWire.keys.contains("sizeIntent"),
      "没有意图时线上不许出现 sizeIntent 这个键（逐字节兼容，实测 \(legacyWire.keys.sorted())）")
  check(legacyWire["heightMeters"] as? Double == 0.42, "旧调用的 height_meters 必须原样保留")
  let legacyJob = coordinator.residentJobs(worldID: world, residentScope: resident).first { $0.name == "旧调用斧头" }!
  check(legacyJob.sizeIntent == nil, "旧调用不产生意图（尺寸推断与今天逐位相同）")
  check(legacyJob.sizeIntentLine == nil, "旧调用的任务行不许因为本契约多出一行")

  // ── 意图回读：守护进程 job JSON → app 记录（面板与回执读同一份） ───────────
  await store.refreshSnapshot()
  let swordRecord = store.jobs.first { $0.id == swordJob.id }
  check(swordRecord?.sizeIntent?.axis == .longest && swordRecord?.sizeIntent?.meters == 1.1,
      "守护进程回显的意图必须能解回 app（实测 \(String(describing: swordRecord?.sizeIntent))）")
  check(swordRecord?.heightMeters == 1.1, "记录里的 height_meters 与意图同源")
  let legacyRecord = store.jobs.first { $0.id == legacyJob.id }
  check(legacyRecord?.sizeIntent == nil, "旧任务的记录里没有意图（是 nil，不是补一个按高度的意图）")

  finish()
 }
}
"""#

let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-size-intent-harness-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let main = temp.appendingPathComponent("Checks.swift"), python = temp.appendingPathComponent("fixture.py")
try program.write(to: main, atomically: true, encoding: .utf8)
try fixture.write(to: python, atomically: true, encoding: .utf8)
let binary = temp.appendingPathComponent("checks")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library"]
    + required.map { sources.appendingPathComponent($0).path } + [main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let run = Process(); run.executableURL = binary; run.arguments = [python.path]
try run.run(); run.waitUntilExit(); exit(run.terminationStatus)
