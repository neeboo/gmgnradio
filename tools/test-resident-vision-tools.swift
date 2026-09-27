// Hostless offline checks for the resident vision tool JSON contract.
// Compiles and RUNS the shipping production sources (ResidentVisionCapture.swift
// + ResidentVisionTools.swift) with a fake frame surface through the same
// ResidentVisionToolbox.handle used by the app's tool channel.
//
// Run:  swift tools/test-resident-vision-tools.swift

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let captureSource = sources.appendingPathComponent("Presence/ResidentVisionCapture.swift")
let toolsSource = sources.appendingPathComponent("Agent/ResidentVisionTools.swift")
guard FileManager.default.fileExists(atPath: captureSource.path),
      FileManager.default.fileExists(atPath: toolsSource.path) else {
    print("FAIL: production vision sources missing")
    exit(1)
}

let harness = #"""
import Foundation
import CoreGraphics
import ImageIO

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value {
        failures += 1
        print("FAIL: \(message)")
    }
}

@MainActor
final class FakeVisionSurface: ResidentVisionSurface {
    enum Behavior {
        case valid
        case wrongWorld(String)
        case explicit(ResidentVisionSurfaceFrameResult)
    }
    var behavior: Behavior
    init(_ behavior: Behavior = .valid) { self.behavior = behavior }

    func captureCurrentObservation(
        request: ResidentVisionCaptureRequest,
        requestedAt: Date
    ) async -> ResidentVisionSurfaceFrameResult {
        switch behavior {
        case .valid:
            let stamp = ResidentVisionRenderedStamp(
                surfaceProfile: "full_stage_drawable", frameIndex: 1,
                capturedAt: requestedAt.addingTimeInterval(0.01),
                worldID: request.worldID,
                residentAvatarID: "resident.pmx",
                residentAvatarFrameRevision: 3,
                residentPosition: [0, 0, 0],
                camera: ResidentVisionCameraStamp(
                    label: "full-stage observer", kind: .fullStageObserver,
                    position: [0, 1.4, 2.1], yaw: 0, pitch: 0,
                    fieldOfViewDegrees: 66, coordinateSpace: "stage"))
            return .frame(ResidentVisionRenderedFrame(
                pixelsBGRA: Data(repeating: 0x80, count: 16 * 4),
                width: 4, height: 4, bytesPerRow: 16, stamp: stamp))
        case let .wrongWorld(world):
            let stamp = ResidentVisionRenderedStamp(
                surfaceProfile: "full_stage_drawable", frameIndex: 1,
                capturedAt: requestedAt.addingTimeInterval(0.01),
                worldID: world, residentAvatarID: nil,
                residentAvatarFrameRevision: nil, residentPosition: nil,
                camera: ResidentVisionCameraStamp(
                    label: "full-stage observer", kind: .fullStageObserver,
                    position: [0, 1.4, 2.1], yaw: 0, pitch: 0,
                    fieldOfViewDegrees: 66, coordinateSpace: "stage"))
            return .frame(ResidentVisionRenderedFrame(
                pixelsBGRA: Data(repeating: 0x80, count: 16 * 4),
                width: 4, height: 4, bytesPerRow: 16, stamp: stamp))
        case let .explicit(result):
            return result
        }
    }
}

@MainActor
func json(_ data: Data) -> [String: Any] {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

@MainActor
func makeToolbox(
    surface: (any ResidentVisionSurface)?,
    root: URL,
    session: ResidentVisionToolbox.Session?
) -> ResidentVisionToolbox {
    let boxed: ResidentVisionToolbox.Session? = session
    return ResidentVisionToolbox(
        surface: surface, fileRoot: root,
        currentSession: { boxed })
}

let worldID = "world.marble-living-cabin"

// MARK: - 合同与参数校验

@MainActor
func testContract() {
    let tool = ResidentVisionToolContract.providerTool()
    let function = tool["function"] as? [String: Any]
    check(function?["name"] as? String == ResidentVisionToolContract.toolName,
          "provider 工具名固定")
    let parameters = function?["parameters"] as? [String: Any]
    let properties = parameters?["properties"] as? [String: Any]
    check(properties?.keys.contains("perspective") == true, "schema 含 perspective")
    check(properties?.keys.contains("reason") == true, "schema 含 reason")
    check(properties?.keys.contains("expected_world_revision") == true,
          "schema 含 expected_world_revision(期望条件)")
    check(properties?.keys.contains("include_inline_image") != true,
          "schema 不含 include_inline_image:base64 图片字节不进模型可见文本")
    check(properties?.keys.contains("path") != true
        && properties?.keys.contains("file_url") != true
        && properties?.keys.contains("output_path") != true,
        "schema 没有任何路径参数:模型不能指定写入位置")
    let perspectiveSchema = properties?["perspective"] as? [String: Any]
    let perspectiveEnum = perspectiveSchema?["enum"] as? [String]
    check(perspectiveEnum == ["current_observation"],
          "schema 只枚举已真实实现的视角,实际 \(String(describing: perspectiveEnum))")
    let schemas = ResidentVisionToolContract.additionalToolSchemas()
    check(schemas.first?["name"] as? String == ResidentVisionToolContract.toolName,
          "additionalTool schema 名称一致")

    let valid = ResidentVisionToolArgumentPolicy.validate([
        "perspective": "current_observation",
        "reason": "看一下房间",
        "expected_world_revision": 12,
    ])
    guard case let .success(input) = valid else {
        check(false, "合法参数应通过")
        return
    }
    check(input.perspective == .currentObservation && input.expectedWorldRevision == 12
        && input.reason == "看一下房间",
        "参数解析结果正确")

    check(ResidentVisionToolArgumentPolicy.validate([
        "perspective": "global_overview"]) == .failure(.invalid("视角尚未实现或不可用")),
        "未实现的离屏视角被拒绝")
    check(ResidentVisionToolArgumentPolicy.validate([
        "expected_world_revision": -3]) == .failure(.invalid("expected_world_revision 需要是非负整数")),
        "负数 revision 被拒绝")
    check(ResidentVisionToolArgumentPolicy.validate([
        "include_inline_image": true]) == .failure(.invalid("包含不支持的参数")),
        "include_inline_image 已从合同移除(图片字节走 handleImage 强类型产物)")
    check(ResidentVisionToolArgumentPolicy.validate([
        "write_path": "/tmp/x.png"]) == .failure(.invalid("包含不支持的参数")),
        "路径参数被拒绝")
}

// MARK: - 工具 JSON 输出

@MainActor
func testToolboxSuccess() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-tools-success-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ResidentVisionToolbox.Session(
        runID: UUID(), worldID: worldID, worldRevision: 12)
    let toolbox = makeToolbox(surface: FakeVisionSurface(), root: root, session: session)

        let response = await toolbox.handle(
            name: ResidentVisionToolContract.toolName,
            argumentsJSON: Data("{}".utf8))
        check(!response.isError, "合法调用成功")
        let object = json(response.data)
        check(object["ok"] as? Bool == true, "ok=true")
        guard let image = object["image"] as? [String: Any] else {
            check(false, "缺少 image 载荷")
            return
        }
        check(image["mime"] as? String == "image/png", "mime 为 image/png")
        check(image["width"] as? Int == 4 && image["height"] as? Int == 4, "图片尺寸")
        check(image["data_base64"] == nil, "文本 JSON 绝不含 base64 图片字节")
        check(!response.data.isEmpty
            && String(data: response.data, encoding: .utf8)?
                .contains("data_base64") != true,
            "文本载荷中不存在 data_base64 字样")
        guard let fileURLString = image["file_url"] as? String,
              let fileURL = URL(string: fileURLString) else {
            check(false, "缺少会话私有 file_url")
            return
        }
        check(ResidentVisionFilePolicy.isScoped(fileURL, root: root), "file_url 落在会话作用域内")
        check(fileURL.path.contains(session.runID.uuidString), "file_url 位于当前居民会话目录")
        guard let metadata = object["metadata"] as? [String: Any] else {
            check(false, "缺少 metadata")
            return
        }
        check(metadata["world_id"] as? String == worldID, "metadata.world_id")
        check(metadata["camera"] != nil, "metadata.camera")
        check(metadata["captured_at"] != nil, "metadata.captured_at(time)")
        check(metadata["perspective"] as? String == "current_observation",
              "metadata.perspective")
        check(metadata["expected_world_revision"] == nil,
              "模型未提供期望 revision 时不得回显/伪造任何 world revision")
        check(metadata["world_revision"] == nil,
              "不存在伪造的 world_revision(渲染器不提供帧的真实 revision)")
        guard let policy = object["policy"] as? [String: Any] else {
            check(false, "缺少 policy")
            return
        }
        check(policy["session_scoped"] as? Bool == true, "policy.session_scoped")
        check(policy["current_resident_session_only"] as? Bool == true,
              "policy 仅当前居民会话")
        check(policy["not_generation_authorization"] as? Bool == true,
              "policy 非生成授权")
        check(policy["never_automatic_capture"] as? Bool == true,
              "policy 不自动拍照")

    // 显式提供 expected_world_revision:仅作为请求条件回显,不代表帧已核对。
    let echoed = await toolbox.handle(
        name: ResidentVisionToolContract.toolName,
        argumentsJSON: Data(#"{"expected_world_revision":12}"#.utf8))
    check(!echoed.isError, "带期望 revision 的调用成功")
    let echoMetadata = json(echoed.data)["metadata"] as? [String: Any]
    check((echoMetadata?["expected_world_revision"] as? NSNumber)?.uint64Value == 12,
          "显式期望 revision 作为请求条件回显")
}

// MARK: - handleImage 强类型图片产物(图片字节不进文本 JSON)

@MainActor
func testToolboxHandleImageSuccess() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-image-lane-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ResidentVisionToolbox.Session(
        runID: UUID(), worldID: worldID, worldRevision: 3)
    let toolbox = makeToolbox(surface: FakeVisionSurface(), root: root, session: session)

    let reply = await toolbox.handleImage(
        name: ResidentVisionToolContract.toolName,
        argumentsJSON: Data(#"{"perspective":"current_observation"}"#.utf8))
    check(!reply.isError, "handleImage 成功调用不是错误")
    guard let image = reply.image else {
        check(false, "handleImage 成功必须返回强类型 ResidentVisionImage")
        return
    }
    check(ResidentVisionPNG.looksPlausible(image.pngData), "强类型产物是真实 PNG")
    let dims = ResidentVisionPNG.decodedDimensions(image.pngData)
    check(dims?.width == image.metadata.width && dims?.height == image.metadata.height,
          "强类型产物 PNG 尺寸与元数据一致")
    check(image.fileURL != nil, "强类型产物带会话私有文件")
    guard let text = String(data: reply.payloadJSON, encoding: .utf8) else {
        check(false, "payloadJSON 可读")
        return
    }
    check(!text.contains("data_base64"), "图片通道 JSON 只含元数据,绝不含 base64")
    check(!text.contains("iVBOR"), "文本里没有 PNG base64 前缀(模型无法假看图)")
    let payload = json(reply.payloadJSON)
    check(payload["ok"] as? Bool == true, "payload ok=true")
    check((payload["metadata"] as? [String: Any])?["world_id"] as? String == worldID,
          "payload 元数据 world_id")
    check(payload["image"] != nil, "payload 含图片位置描述(mime/尺寸/file_url)")
}

@MainActor
func testToolboxHandleImageFailures() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-image-fail-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ResidentVisionToolbox.Session(
        runID: UUID(), worldID: worldID, worldRevision: 5)

    // 无画面:帧源显式失败。
    let noPicture = await makeToolbox(
        surface: FakeVisionSurface(
            .explicit(.failure(code: .noPicture, message: "无可见画面"))),
        root: root, session: session
    ).handleImage(
        name: ResidentVisionToolContract.toolName,
        argumentsJSON: Data("{}".utf8))
    check(noPicture.isError && noPicture.image == nil,
          "失败时 handleImage 不返回图片")
    let npError = json(noPicture.payloadJSON)["error"] as? [String: Any]
    check(npError?["code"] as? String == "no_picture", "无画面错误码 no_picture")

    // 旧空间:帧属于别的空间 → stale_world。
    let stale = await makeToolbox(
        surface: FakeVisionSurface(.wrongWorld("world.other")),
        root: root, session: session
    ).handleImage(
        name: ResidentVisionToolContract.toolName,
        argumentsJSON: Data("{}".utf8))
    check(stale.isError && stale.image == nil, "旧空间失败无图片")
    let staleError = json(stale.payloadJSON)["error"] as? [String: Any]
    check(staleError?["code"] as? String == "stale_world", "旧空间错误码 stale_world")

    // 会话不匹配。
    let orphan = await makeToolbox(
        surface: FakeVisionSurface(), root: root, session: nil
    ).handleImage(
        name: ResidentVisionToolContract.toolName,
        argumentsJSON: Data("{}".utf8))
    check(orphan.isError && orphan.image == nil, "会话失效失败无图片")
    let orphanError = json(orphan.payloadJSON)["error"] as? [String: Any]
    check(orphanError?["code"] as? String == "session_mismatch",
          "会话失效错误码 session_mismatch")

    // 未知工具 / 坏 JSON / 非法参数。
    let unknown = await makeToolbox(surface: FakeVisionSurface(), root: root, session: session)
        .handleImage(name: "capture_desktop", argumentsJSON: Data("{}".utf8))
    check(unknown.isError && unknown.image == nil
        && (json(unknown.payloadJSON)["error"] as? [String: Any])?["code"] as? String
            == "tool_not_allowed",
        "未知工具错误码 tool_not_allowed")
    let badJSON = await makeToolbox(surface: FakeVisionSurface(), root: root, session: session)
        .handleImage(name: ResidentVisionToolContract.toolName,
                     argumentsJSON: Data("not json".utf8))
    check(badJSON.isError && badJSON.image == nil, "坏 JSON 失败无图片")
    let badArgs = await makeToolbox(surface: FakeVisionSurface(), root: root, session: session)
        .handleImage(name: ResidentVisionToolContract.toolName,
                     argumentsJSON: Data(#"{"perspective":"resident_eye"}"#.utf8))
    check(badArgs.isError && badArgs.image == nil
        && (json(badArgs.payloadJSON)["error"] as? [String: Any])?["code"] as? String
            == "invalid_arguments",
        "非法参数错误码 invalid_arguments")

    // handleImage 与 handle 对同一失败给出相同错误码。
    let staleHandle = await makeToolbox(
        surface: FakeVisionSurface(.wrongWorld("world.other")),
        root: root, session: session
    ).handle(name: ResidentVisionToolContract.toolName,
             argumentsJSON: Data("{}".utf8))
    check((json(staleHandle.data)["error"] as? [String: Any])?["code"] as? String
        == "stale_world",
        "handle 与 handleImage 错误码一致")
}

@MainActor
func testToolboxFailures() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-vision-tools-failures-\(UUID())")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ResidentVisionToolbox.Session(
        runID: UUID(), worldID: worldID, worldRevision: 5)

        // 旧空间:帧属于别的空间 → stale_world
        let staleToolbox = makeToolbox(
            surface: FakeVisionSurface(.wrongWorld("world.other")),
            root: root, session: session)
        let stale = await staleToolbox.handle(
            name: ResidentVisionToolContract.toolName,
            argumentsJSON: Data("{}".utf8))
        check(stale.isError, "旧空间失败")
        let staleError = json(stale.data)["error"] as? [String: Any]
        check(staleError?["code"] as? String == "stale_world", "旧空间错误码 stale_world")

        // 无画面:帧源显式失败
        let noPictureToolbox = makeToolbox(
            surface: FakeVisionSurface(
                .explicit(.failure(code: .noPicture, message: "无可见画面"))),
            root: root, session: session)
        let noPicture = await noPictureToolbox.handle(
            name: ResidentVisionToolContract.toolName,
            argumentsJSON: Data("{}".utf8))
        check(noPicture.isError, "无画面失败")
        let npError = json(noPicture.data)["error"] as? [String: Any]
        check(npError?["code"] as? String == "no_picture", "无画面错误码 no_picture")

        // 会话不匹配:本轮居民会话已结束/切换
        let orphanToolbox = makeToolbox(
            surface: FakeVisionSurface(), root: root, session: nil)
        let orphan = await orphanToolbox.handle(
            name: ResidentVisionToolContract.toolName,
            argumentsJSON: Data("{}".utf8))
        check(orphan.isError, "会话失效失败")
        let orphanError = json(orphan.data)["error"] as? [String: Any]
        check(orphanError?["code"] as? String == "session_mismatch",
              "会话失效错误码 session_mismatch")

        // 未开放工具
        let unknown = await makeToolbox(surface: FakeVisionSurface(), root: root, session: session)
            .handle(name: "capture_desktop", argumentsJSON: Data("{}".utf8))
        check(unknown.isError, "未知工具被拒")
        check((json(unknown.data)["error"] as? [String: Any])?["code"] as? String
            == "tool_not_allowed", "未知工具错误码")

        // 坏 JSON / 非法参数
        let badJSON = await makeToolbox(surface: FakeVisionSurface(), root: root, session: session)
            .handle(name: ResidentVisionToolContract.toolName,
                    argumentsJSON: Data("not json".utf8))
        check(badJSON.isError, "坏 JSON 被拒")
        let badArgs = await makeToolbox(surface: FakeVisionSurface(), root: root, session: session)
            .handle(name: ResidentVisionToolContract.toolName,
                    argumentsJSON: Data(#"{"perspective":"resident_eye"}"#.utf8))
        check(badArgs.isError, "未实现视角参数被拒")
        let badArgsError = json(badArgs.data)["error"] as? [String: Any]
    check(badArgsError?["code"] as? String == "invalid_arguments",
          "非法参数错误码 invalid_arguments")
}

@main
struct Main {
    @MainActor
    static func main() async {
        testContract()
        await testToolboxSuccess()
        await testToolboxFailures()
        await testToolboxHandleImageSuccess()
        await testToolboxHandleImageFailures()
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident vision tool checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-resident-vision-tools-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Tests.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("vision-tools")

func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compiled = try run("/usr/bin/swiftc", [
    "-parse-as-library",
    "-framework", "CoreGraphics",
    "-framework", "ImageIO",
    captureSource.path,
    toolsSource.path,
    program.path,
    "-o", executable.path,
])
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))
