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
                "Presence/WishMachineCoordinator.swift", "Agent/ResidentWishMachineTools.swift"]
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
// 旧字段与意图的**唯一**判据在同一处：校验与可读拒绝共用它，所以不可能各说一套。
guard sourceContains("Agent/ResidentWishMachineTools.swift",
    ["sizeIntentProblem(arguments)", "func parseSizeIntent", "先问一句"],
    "许愿工具没有把「用户没说就先问」钉在参数契约上") else { exit(1) }
// 生成入库：意图优先于自动推断，而且落进世界状态的那一份尺寸就是按它算的。
guard sourceContains("App/GMGNRadioApp.swift",
    ["WorldPropSizePolicy.intended(", "sizeIntent: sizeIntent"],
    "生成入库没有把尺寸意图落成世界尺寸（那把剑仍会按高度被算成 8.28 m）") else { exit(1) }
// 提示词层面也要钉住：用户说了就按他说的填，没说就先问。
guard sourceContains("App/GMGNRadioApp.swift",
    ["submit_wish_generation 的 size_intent", "先问一句", "axis=longest", "axis=height"],
    "系统提示没有写清尺寸意图怎么填（agent 会继续猜一个高度）") else { exit(1) }

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
  func submitTool() -> ResidentWorldToolSession.AdditionalTool {
      ResidentWishMachineTools(coordinator: coordinator, worldID: world, residentScope: resident,
          authorizationID: grant, isCurrent: { true }).tools.first { $0.name == "submit_wish_generation" }!
  }
  try freshGrant()
  let submit = submitTool()

  // ── 工具的参数契约：尺寸说清楚才放行，说错给可读原因 ──────────────────────
  let schema = submit.inputSchema
  let properties = schema["properties"] as? [String: Any] ?? [:]
  let intentSchema = properties["size_intent"] as? [String: Any] ?? [:]
  let intentProperties = intentSchema["properties"] as? [String: Any] ?? [:]
  check(properties["size_intent"] != nil, "提交工具的 schema 必须带尺寸意图参数")
  check(intentProperties["axis"] != nil, "尺寸意图必须说得出哪根轴")
  let requiredArguments = Set(schema["required"] as? [String] ?? [])
  check(requiredArguments == ["attachment_id", "name"],
      "尺寸是二选一，不能把旧字段列成必需（实测 \(requiredArguments.sorted())）")
  check(submit.description.contains("先问一句") && submit.description.contains("不要自己猜"),
      "工具说明必须钉住「用户没说尺寸就先问」")
  check((intentProperties["axis"] as? [String: Any])?["enum"] as? [String] == ["longest", "height"],
      "轴只认 longest / height（契约字面量）")

  // 缺失尺寸 / 非法轴 / 越界 / 猜出来的出处：必须是**可读拒绝**，而且不许发出提交。
  let base: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "剑"]
  let rejections: [(String, [String: Any], String)] = [
      ("一个尺寸都没给", base, "先问"),
      ("轴名非法", base.merging(["size_intent": ["axis": "width", "meters": 1.1] as [String: Any]]) { _, new in new }, "longest"),
      ("米数越界", base.merging(["size_intent": ["axis": "longest", "meters": 9] as [String: Any]]) { _, new in new }, "0.01—3"),
      ("出处是猜的", base.merging(["size_intent": ["axis": "longest", "meters": 1.1, "source": "default"] as [String: Any]]) { _, new in new }, "先问"),
      ("尺寸给了两遍", base.merging(["height_meters": 1.1, "size_intent": ["axis": "height", "meters": 1.1] as [String: Any]]) { _, new in new }, "只能给一个"),
  ]
  for (label, args, needle) in rejections {
      check(!submit.validate(args), "\(label)：参数校验必须拒绝")
      let result = await submit.handle("invalid-" + label, arguments(args))
      let payload = parse(result)
      check(result.isError && payload["code"] as? String == "invalid_size_intent",
          "\(label)：必须是 invalid_size_intent（实测 \(String(describing: payload["code"]))）")
      check((payload["message"] as? String)?.contains(needle) == true,
          "\(label)：原因必须可读且提到 \(needle)（实测 \(String(describing: payload["message"]))）")
  }
  check(readSubmits(scratch).isEmpty, "被拒的尺寸一个提交都不许发出去（实测 \(readSubmits(scratch).count) 条）")

  // ── 「一把 1.1 米的剑」：线上必须说清是最长边 1.1 米 ──────────────────────
  try freshGrant()
  let swordTool = submitTool()
  let sword: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "2B 白色长剑",
                              "size_intent": ["axis": "longest", "meters": 1.1, "source": "user"] as [String: Any]]
  check(swordTool.validate(sword), "合法的尺寸意图必须放行")
  let swordResult = await swordTool.handle("sword", arguments(sword))
  check(!swordResult.isError, "最长边意图必须受理（实测 \(parse(swordResult))）")
  try await until("剑的提交落到替身") { readSubmits(scratch).count == 1 }
  let swordWire = readSubmits(scratch)[0]
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
  try await until("咖啡机的提交落到替身") { readSubmits(scratch).count == 2 }
  let machineWire = readSubmits(scratch)[1]
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
  try await until("旧调用落到替身") { readSubmits(scratch).count == 3 }
  let legacyWire = readSubmits(scratch)[2]
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
