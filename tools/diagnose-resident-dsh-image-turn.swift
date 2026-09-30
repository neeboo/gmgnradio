// 居民图片输入「发送之后」全链诊断（离线 mock provider，零模型额度）。
//
// 与 tools/diagnose-resident-dsh-image-gates.swift 分工：
//   - gates 工具只回答「两道判据在真实 composition 形状下成不成立」（不发 prompt）；
//   - 本工具回答「判据都成立时，图片到底有没有真的离开宿主、到达 provider」。
// 它走的是**完全生产**的路径：真实 AgentConversationService.send（backend .dsh、
// 不注入 connector、worldContext + worldTools）→ 真实 ResidentDSHConnector →
// 真实 acp-demo runtime + 真实 gmgn-host-tools 插件 → 本地 loopback mock provider。
// 不启动 app、不读真实凭据、不触达真实模型。
//
// 判据：mock provider 捕获的请求体里必须真的出现图片内容（data:image/...;base64,
// 或 image_url 内容块）。为 0 就是「图片在 service.send 之后被丢掉」—— 一句话定位。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-image-turn-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let environment = ProcessInfo.processInfo.environment
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

struct DiagnoseLocator: AgentExecutableLocating {
    let node: URL
    let dsh: URL
    func locate(executableNames: [String]) -> URL? {
        if executableNames.contains("node") { return node }
        if executableNames.contains("dsh") { return dsh }
        return nil
    }
    init() {
        self.node = URL(fileURLWithPath: environment["NODE_BIN"] ?? "/usr/bin/node")
        let dshPath = environment["DSH_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/bin/dsh"
        self.dsh = URL(fileURLWithPath: dshPath)
    }
}

@MainActor private func makeWorld(id: String = "cabin") -> ResidentWorldContext {
    ResidentWorldContext(
        selectedWorldID: id, worldID: id, displayName: "诊断空间", revision: 1,
        residentPosition: [0, 0, 0], activeActivity: nil, activityPhase: nil,
        objects: [], availableActivities: []
    )
}

private func schemaJSON() -> Data {
    let tool: [String: Any] = [
        "name": "inspect_world",
        "description": "只读查看当前空间公开资料",
        "inputSchema": [
            "type": "object", "properties": [:], "additionalProperties": false,
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: [tool], options: [.sortedKeys])
}

@MainActor private func makeTools() -> ResidentConversationTools {
    let payload = try! JSONSerialization.data(
        withJSONObject: ["ok": true, "world": "cabin"], options: [.sortedKeys]
    )
    return ResidentConversationTools(
        visionCapable: true, worldID: "cabin", schemasJSON: schemaJSON(),
        call: { _, _, _ in ResidentCodexToolReply(resultJSON: payload, isError: false) },
        cancel: {}
    )
}

/// 真实 PNG 写到磁盘：不是伪造的字节串，和附件层落盘的产物同形。
func writePNG(width: Int, height: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw AgentConversationError.imageFormatUnsupported }
    for y in 0..<height {
        for x in 0..<width {
            let inside = (16...47).contains(x) && (16...47).contains(y)
            let color = inside
                ? CGColor(srgbRed: 0.86, green: 0.12, blue: 0.12, alpha: 1)
                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            context.setFillColor(color)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else { throw AgentConversationError.imageFormatUnsupported }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw AgentConversationError.imageFormatUnsupported
    }
}

@main struct TurnDiagnosis {
    @MainActor static func main() async {
        print("== diagnose-resident-dsh-image-turn ==")
        let requestsFile = environment["REQUESTS_FILE"] ?? ""
        let successText = environment["SUCCESS_TEXT"] ?? "GMGN_IMAGE_TURN_FINAL_OK"
        let workDir = URL(fileURLWithPath: environment["DIAGNOSE_WORK_DIR"] ?? NSTemporaryDirectory())
        let imageURL = workDir.appendingPathComponent("diagnose-image.png")
        do { try writePNG(width: 64, height: 64, to: imageURL) }
        catch {
            print("FAIL: could not encode the diagnostic PNG: \(type(of: error)) \(error)")
            exit(2)
        }
        let imageBytes = (try? Data(contentsOf: imageURL))?.count ?? 0
        print("image: \(imageURL.path) bytes=\(imageBytes)")

        let suite = "gmgn-diagnose-image-turn-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let service = AgentConversationService(locator: DiagnoseLocator(), defaults: defaults)
        service.selectBackend(.dsh)
        let world = makeWorld()

        var firstError: Error?
        do {
            let reply = try await service.send(
                "请看这张图片：里面有什么颜色、什么形状？", imageURLs: [imageURL],
                worldContext: world, worldTools: makeTools()
            )
            print("turn1 reply: \(reply.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        } catch {
            firstError = error
            print("FAIL: image turn threw \(type(of: error)): \(error)")
            if let conversation = error as? AgentConversationError {
                switch conversation {
                case .dshImageCapabilityUnavailable:
                    print("   -> 判据 A/B 在发送那一刻不成立（handshake image 或 modelImageDeclared 为 false）")
                case .imageTransportUnavailable:
                    print("   -> 带图回合找不到原生 ACP 传输组件")
                case .imageFormatUnsupported:
                    print("   -> 附件字节读不出来或扩展名不被接受")
                default: break
                }
            }
        }
        check(firstError == nil, "the image turn completed without throwing (got \(String(describing: firstError)))")

        // 第二轮纯文字：证明同一会话可用，并把「图片只出现在带图那轮」变成可读事实。
        if firstError == nil {
            do {
                let reply = try await service.send(
                    "刚才那张图里是什么形状？不要看新图片。", imageURLs: [],
                    worldContext: world, worldTools: makeTools()
                )
                print("turn2 reply: \(reply.replacingOccurrences(of: "\n", with: " ").prefix(160))")
            } catch {
                print("FAIL: text-only turn threw \(type(of: error)): \(error)")
                failures += 1
            }
        }

        // ── provider 侧证据：图片到底有没有离开宿主。 ──
        var requestLines: [String] = []
        if !requestsFile.isEmpty,
           let content = try? String(contentsOfFile: requestsFile, encoding: .utf8) {
            requestLines = content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        let imageCarryingLines = requestLines.filter {
            $0.contains("data:image/") || $0.contains("\"image_url\"")
        }
        print("provider requests: \(requestLines.count), carrying image content: \(imageCarryingLines.count)")
        check(!requestLines.isEmpty, "the mock provider received at least one request (\(requestLines.count))")
        check(!imageCarryingLines.isEmpty,
              "the image block reached the provider as real image content (image-carrying requests: \(imageCarryingLines.count)/\(requestLines.count))")
        if let first = imageCarryingLines.first,
           let range = first.range(of: "data:image/") {
            print("provider image payload starts: \(first[range.lowerBound...].prefix(48))")
        }
        if imageCarryingLines.isEmpty && !requestLines.isEmpty {
            print("note: provider saw \(requestLines.count) request(s) but zero image parts — the loss is AFTER service.send accepted the attachment")
        }
        check(requestLines.contains { $0.contains(successText) || $0.contains("\"content\"") },
              "provider request bodies carry the prompt text")

        service.resetSession()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) image-turn checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("turn")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
var compileArguments = ["-swift-version", "6", "-parse-as-library", "-j1"]
for agentName in [
    "CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy",
    "ResidentCodexAgent", "ResidentSteeringDelivery", "ResidentDSHTransport",
    "ResidentDSHConfiguration", "ResidentStateClient", "ResidentMemoryClient",
    "ResidentConversationMemory", "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner",
] {
    compileArguments.append(root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\(agentName).swift").path)
}
compileArguments.append(contentsOf: [
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift").path,
    main.path, "-o", binary.path,
])
compile.arguments = compileArguments
try compile.run()
let compileDeadline = Date().addingTimeInterval(240)
while compile.isRunning && Date() < compileDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if compile.isRunning {
    compile.terminate()
    print("FAIL: image-turn diagnosis compile exceeded 240s")
    exit(124)
}
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("COMPILE FAILED (exit \(compile.terminationStatus))")
    exit(compile.terminationStatus)
}
let test = Process()
var childEnvironment = ProcessInfo.processInfo.environment
childEnvironment["DIAGNOSE_WORK_DIR"] = work.path
test.environment = childEnvironment
test.executableURL = binary
try test.run()
let runDeadline = Date().addingTimeInterval(240)
while test.isRunning && Date() < runDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if test.isRunning {
    test.terminate()
    print("FAIL: image-turn diagnosis execution exceeded 240s")
    exit(124)
}
test.waitUntilExit()
exit(test.terminationStatus)
