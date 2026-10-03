// 居民 DSH 原生宿主工具通道离线回归（纯 CPU / 无 DSH / 无模型 / 无网络）：
// 编译并运行生产文件
//   apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift
//   apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift
// 与 tools/resident-dsh-host-tools-support.swift 的真实逻辑，经本机 UDS 全链路验证：
//   grant(armed) → IPC 调用 → 宿主 secret 校验 → 名称边界 → 原 schema 复核 →
//   授权闸 → 宿主 handler → 规范 JSON 回插件形态客户端。
// 覆盖：每轮授权不复用（revoke 即撤销、旧 secret 失效、re-arm 后新 secret 生效）、
// 未知工具/非法参数/无法核验 schema → 拒绝且宿主零执行、宿主工具错误与成功分开、
// 图片回执、overlay 行与 grant/插件文件落盘权限、stop 清理；
// 执行前取消竞态（MainActor 边界重新核验同一授权代/secret）：revoke、revoke+re-arm、
// stop 唤醒等待中的 handler、挂死客户端不堵死其它调用、执行中请求取消语义。
// 编译门与主代理验收一致：`-swift-version 6 -parse-as-library` 真实编译并运行。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-dsh-host-channel-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation

/// @MainActor 上的 handler 调用计数（与 handler 同在 MainActor，无跨域）。
@MainActor final class MainActorCallCounter {
    private var count = 0
    func increment() { count += 1 }
    var current: Int { count }
}

/// 客户端线程结果的线程安全盒（并发断言用）。
final class ClientResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (payload: NSDictionary?, error: String?) = (nil, nil)
    func set(_ value: (payload: NSDictionary?, error: String?)) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }
    var value: (payload: NSDictionary?, error: String?) {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

@main struct ResidentDSHHostChannelTests {
    @MainActor static func main() async throws {
        var checks = ResidentDSHHostChecks()
        func runClient(_ block: @escaping @Sendable () -> (payload: NSDictionary?, error: String?)) async -> (payload: NSDictionary?, error: String?) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: block())
                }
            }
        }
        // 只连不发（挂死客户端）：连接后保持打开但不写请求。
        func rawConnect(path: String) -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return -1 }
            guard let port = UInt16(path.split(separator: ":").last ?? "") else { close(fd); return -1 }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result != 0 { close(fd); return -1 }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            return fd
        }
        // 同步信号量等待（非 async）：在 @MainActor 的 async main 里调用它会真实占住
        // 主 actor 线程 —— 已排队的 MainActor 任务无法运行，这是「执行前取消竞态」
        // 回归的前提（与主代理验收测试的 holdMainActorForQueuedRequest 同构）。
        func syncWait(_ semaphore: DispatchSemaphore, timeout: DispatchTime = .distantFuture) {
            _ = semaphore.wait(timeout: timeout)
        }
        // 异步信号量等待：让出当前 actor，供等待客户端收尾等无需占住主 actor 的场景。
        func asyncWait(_ semaphore: DispatchSemaphore, timeout: DispatchTime = .distantFuture) async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    _ = semaphore.wait(timeout: timeout)
                    continuation.resume()
                }
            }
        }

        // 1) 清单解析：合法集合、重复、带前缀、畸形 inputSchema fail-closed。
        do {
            let registrations = try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas)
            checks.expectEqual(registrations.count, 2, "C1 解析两个正式工具")
            let names = registrations.map(\.declaredName).sorted()
            checks.expectEqual(names, ["gmgn_read_wish_generation", "gmgn_submit_wish_generation"], "C1 暴露名统一 gmgn_ 前缀")
            checks.check(registrations.allSatisfy { $0.canonicalName != $0.declaredName }, "C1 canonical 无前缀")
        }
        do {
            let dup = try! JSONSerialization.data(withJSONObject: [
                ["name": "a", "inputSchema": ["type": "object"]],
                ["name": "a", "inputSchema": ["type": "object"]],
            ])
            do { _ = try ResidentDSHHostToolSet.parse(schemasJSON: dup); checks.check(false, "C1 重名必须拒绝") } catch {}
            let prefixed = try! JSONSerialization.data(withJSONObject: [
                ["name": "gmgn_a", "inputSchema": ["type": "object"]],
            ])
            do { _ = try ResidentDSHHostToolSet.parse(schemasJSON: prefixed); checks.check(false, "C1 带前缀 canonical 必须拒绝") } catch {}
            let noSchema = try! JSONSerialization.data(withJSONObject: [
                ["name": "b", "inputSchema": "oops"],
            ])
            do { _ = try ResidentDSHHostToolSet.parse(schemasJSON: noSchema); checks.check(false, "C1 畸形 inputSchema 必须拒绝") } catch {}
        }

        // 2) 启动通道（armed）+ overlay 行（自建短名私有目录）。
        let log = ResidentDSHHostCallLog()
        let registrations = try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas)
        let channel = try ResidentDSHHostToolsChannel.start(
            configuration: ResidentDSHHostToolsChannel.Configuration(
                scope: "world.cabin", worldID: "cabin-1",
                registrations: registrations,
                handler: residentDSHHostToolsTestHandler(log: log, scope: "world.cabin")
            )
        )
        defer { channel.stop() }
        do {
            let dirAttrs = try FileManager.default.attributesOfItem(atPath: channel.directoryURL.path)
            checks.expectEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700, "C2 通道目录 0700")
            checks.check(channel.directoryURL.path.count < 100, "C2 私有目录短路径（socket 需 <104）")
        } catch { checks.check(false, "C2 目录属性读取失败") }
        checks.check(FileManager.default.fileExists(atPath: channel.pluginFileURL.path), "C2 插件文件已写")
        checks.check(FileManager.default.fileExists(atPath: channel.grantFileURL.path), "C2 grant 文件已写")
        let overlay = ResidentDSHHostToolsOverlay.hostToolsRows(pluginFileURL: channel.pluginFileURL)
        checks.expectContains(overlay, "id: gmgn-host-tools", "C2 overlay 含插件 insert")
        checks.expectContains(overlay, "name: '\(channel.pluginFileURL.path)'", "C2 overlay 带插件路径")
        checks.check(!overlay.contains("config:"), "C2 overlay 无 config（grant 由插件同目录解析）")
        do {
            let pluginAttrs = try FileManager.default.attributesOfItem(atPath: channel.pluginFileURL.path)
            let grantAttrs = try FileManager.default.attributesOfItem(atPath: channel.grantFileURL.path)
            checks.expectEqual((pluginAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "C2 插件 0600")
            checks.expectEqual((grantAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "C2 grant 0600")
        } catch { checks.check(false, "C2 权限属性读取失败") }

        // grant 状态：armed + secret/socket 存在（插件视角）。
        let grantObject = ResidentDSHHostSupportSchema.object(try Data(contentsOf: channel.grantFileURL))
        checks.expectEqual(grantObject?["state"] as? String, "armed", "C2 grant state=armed")
        let secret = grantObject?["secret"] as? String ?? ""
        checks.check(!secret.isEmpty, "C2 grant 有 secret")
        let socketFromGrant = (grantObject?["endpoint"] as? [String: Any])?["address"] as? String ?? ""
        checks.expectEqual(socketFromGrant, channel.socketPath, "C2 grant socketPath 与通道一致")
        let toolsInGrant = grantObject?["tools"] as? [[String: Any]] ?? []
        checks.expectEqual(toolsInGrant.count, 2, "C2 grant 携带两个工具")

        // 3) 正常调用：宿主执行、结果回插件形态客户端。
        do {
            let result = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: secret, name: "gmgn_read_wish_generation", arguments: [:], callID: UUID().uuidString)
            }
            guard let payload = result.payload else {
                checks.check(false, "C3 正常调用应得到回复：\(result.error ?? "")"); return
            }
            checks.expectEqual(payload["ok"] as? Bool, true, "C3 ok=true")
            let data = payload["data"] as? [String: Any]
            checks.expectEqual(data?["running"] as? Bool, false, "C3 data.running=false")
            checks.expectEqual(log.count, 1, "C3 宿主执行一次")
            checks.check(log.contains(canonical: "read_wish_generation"), "C3 宿主收到 canonical 名")
        }

        // 4) 非法 secret → 拒绝；宿主零执行。
        do {
            let result = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: "wrong", name: "gmgn_read_wish_generation", arguments: [:], callID: UUID().uuidString)
            }
            let error = result.payload?["error"] as? [String: Any]
            checks.expectEqual(error?["code"] as? String, "grant_revoked", "C4 错误 secret 拒绝")
            checks.expectEqual(log.count, 1, "C4 非法 secret 不执行")
        }

        // 5) 未知工具（含剥前缀试探/原生 web 名）→ 拒绝且不执行。
        do {
            for declared in ["gmgn_nonexistent", "read_wish_generation", "web_search"] {
                let result = await runClient {
                    residentDSHHostClientCall(socketPath: channel.socketPath, secret: secret, name: declared, arguments: [:], callID: UUID().uuidString)
                }
                let error = result.payload?["error"] as? [String: Any]
                checks.expectEqual(error?["code"] as? String, "tool_not_allowed", "C5 \(declared) 拒绝")
            }
            checks.expectEqual(log.count, 1, "C5 未知工具全部不执行")
        }

        // 6) 非法参数（缺必需/未声明属性）→ invalid_arguments，宿主零执行。
        do {
            let missing = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: secret, name: "gmgn_submit_wish_generation", arguments: ["attachment_id": "uuid"], callID: UUID().uuidString)
            }
            let error = missing.payload?["error"] as? [String: Any]
            checks.expectEqual(error?["code"] as? String, "invalid_arguments", "C6 缺必需属性拒绝")
            let extra = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: secret, name: "gmgn_submit_wish_generation", arguments: ["attachment_id": "uuid", "name": "月光大剑", "height_meters": 1.2, "evil": true], callID: UUID().uuidString)
            }
            let error2 = extra.payload?["error"] as? [String: Any]
            checks.expectEqual(error2?["code"] as? String, "invalid_arguments", "C6 未声明属性拒绝")
            checks.expectEqual(log.count, 1, "C6 非法参数不执行")
        }

        // 7) 合法 submit → 执行；宿主报错（isError）与成功分开（tool_error + data）。
        do {
            let good = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: secret, name: "gmgn_submit_wish_generation", arguments: ["attachment_id": "550e8400-e29b-41d4-a716-446655440000", "name": "月光大剑", "height_meters": 1.2], callID: UUID().uuidString)
            }
            checks.expectEqual(good.payload?["ok"] as? Bool, true, "C7 合法 submit 成功")
            checks.expectEqual(log.count, 2, "C7 submit 已执行")
            let failed = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: secret, name: "gmgn_submit_wish_generation", arguments: ["attachment_id": "x", "name": "fail", "height_meters": 1.0], callID: UUID().uuidString)
            }
            checks.expectEqual(failed.payload?["ok"] as? Bool, false, "C7 工具错误 ok=false")
            let error = failed.payload?["error"] as? [String: Any]
            checks.expectEqual(error?["code"] as? String, "tool_error", "C7 工具错误 code=tool_error")
            checks.expectEqual(log.count, 3, "C7 工具错误也走宿主执行（领域失败≠协议失败）")
        }

        // 8) schema 含无法核验约束 → schema_unsupported fail-closed（注册另一通道）。
        do {
            let oddSchema: [[String: Any]] = [[
                "name": "odd_tool",
                "description": "",
                "inputSchema": ["type": "object", "properties": ["p": ["type": "string", "pattern": "^[a-z]+$"]], "required": [], "additionalProperties": false],
            ]]
            let oddJSON = try JSONSerialization.data(withJSONObject: oddSchema, options: [.sortedKeys])
            let oddLog = ResidentDSHHostCallLog()
            let oddChannel = try ResidentDSHHostToolsChannel.start(
                configuration: .init(scope: "world.cabin", worldID: "cabin-1", registrations: try ResidentDSHHostToolSet.parse(schemasJSON: oddJSON), handler: residentDSHHostToolsTestHandler(log: oddLog, scope: "world.cabin"))
            )
            defer { oddChannel.stop() }
            let oddGrant = ResidentDSHHostSupportSchema.object(try Data(contentsOf: oddChannel.grantFileURL))
            let oddSecret = oddGrant?["secret"] as? String ?? ""
            let result = await runClient {
                residentDSHHostClientCall(socketPath: oddChannel.socketPath, secret: oddSecret, name: "gmgn_odd_tool", arguments: ["p": "abc"], callID: UUID().uuidString)
            }
            let error = result.payload?["error"] as? [String: Any]
            checks.expectEqual(error?["code"] as? String, "schema_unsupported", "C8 无法核验约束拒绝")
            checks.expectEqual(oddLog.count, 0, "C8 schema_unsupported 宿主零执行")
        }

        // 9) 每轮授权不可复用：revoke → 拒绝；re-arm 换 secret → 旧 secret 拒绝、新 secret 成功。
        do {
            channel.revoke()
            let afterRevoke = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: secret, name: "gmgn_read_wish_generation", arguments: [:], callID: UUID().uuidString)
            }
            let error = afterRevoke.payload?["error"] as? [String: Any]
            checks.expectEqual(error?["code"] as? String, "grant_revoked", "C9 撤销后拒绝（旧 secret）")
            checks.check(!FileManager.default.fileExists(atPath: channel.grantFileURL.path), "C9 revoke 删除 grant 文件")
            let before = log.count
            try channel.arm(worldRevision: 42)
            let grant2 = ResidentDSHHostSupportSchema.object(try Data(contentsOf: channel.grantFileURL))
            checks.expectEqual(grant2?["state"] as? String, "armed", "C9 re-arm state=armed")
            let newSecret = grant2?["secret"] as? String ?? ""
            checks.check(!newSecret.isEmpty && newSecret != secret, "C9 re-arm 轮换 secret")
            let oldSecretCall = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: secret, name: "gmgn_read_wish_generation", arguments: [:], callID: UUID().uuidString)
            }
            checks.expectEqual((oldSecretCall.payload?["error"] as? [String: Any])?["code"] as? String, "grant_revoked", "C9 上一轮 secret 不再可用")
            let newSecretCall = await runClient {
                residentDSHHostClientCall(socketPath: channel.socketPath, secret: newSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: UUID().uuidString)
            }
            checks.expectEqual(newSecretCall.payload?["ok"] as? Bool, true, "C9 本轮新 secret 生效")
            checks.check(log.count == before + 1, "C9 撤销期调用零执行、新轮一次执行")
        }

        // 10) 图片回执：回复含 image（base64 png）。
        do {
            let pngLog = ResidentDSHHostCallLog()
            let pngRegistrations = try ResidentDSHHostToolSet.parse(schemasJSON: try JSONSerialization.data(withJSONObject: [["name": "capture_space_photo", "description": "拍照", "inputSchema": ["type": "object", "properties": [:], "required": [], "additionalProperties": false]]]))
            let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
            let imageChannel = try ResidentDSHHostToolsChannel.start(
                configuration: .init(scope: "world.cabin", worldID: "cabin-1", registrations: pngRegistrations, handler: { request in
                    pngLog.append(request.canonicalName, callID: request.callID, argumentsJSON: request.argumentsJSON)
                    return ResidentDSHHostToolReply(resultJSON: try! JSONSerialization.data(withJSONObject: ["ok": true, "captured": true]), isError: false, imagePNGData: fakePNG)
                })
            )
            defer { imageChannel.stop() }
            let imgGrant = ResidentDSHHostSupportSchema.object(try Data(contentsOf: imageChannel.grantFileURL))
            let imgSecret = imgGrant?["secret"] as? String ?? ""
            let result = await runClient {
                residentDSHHostClientCall(socketPath: imageChannel.socketPath, secret: imgSecret, name: "gmgn_capture_space_photo", arguments: [:], callID: UUID().uuidString)
            }
            checks.expectEqual(result.payload?["ok"] as? Bool, true, "C10 拍照成功")
            let image = result.payload?["image"] as? [String: Any]
            checks.expectEqual(image?["mimeType"] as? String, "image/png", "C10 image.mimeType")
            checks.expectContains(image?["base64"] as? String ?? "", "iVBORw0KGgo", "C10 image.base64 为真实 PNG 前缀")
        }

        // 11) stop() 清理：grant/插件 socket 清理、新连接失败。
        do {
            let stopLog = ResidentDSHHostCallLog()
            let stopChannel = try ResidentDSHHostToolsChannel.start(
                configuration: .init(scope: "s", worldID: "w", registrations: try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas), handler: residentDSHHostToolsTestHandler(log: stopLog, scope: "s"))
            )
            stopChannel.stop()
            checks.check(!FileManager.default.fileExists(atPath: stopChannel.grantFileURL.path), "C11 stop 删除 grant")
            checks.check(!FileManager.default.fileExists(atPath: stopChannel.socketPath), "C11 stop 删除 socket")
            let result = await runClient {
                residentDSHHostClientCall(socketPath: stopChannel.socketPath, secret: "x", name: "gmgn_read_wish_generation", arguments: [:], callID: UUID().uuidString)
            }
            checks.check(result.payload == nil, "C11 stop 后新连接无回复（拒绝）")
            checks.expectEqual(stopLog.count, 0, "C11 stop 后零执行")
        }

        // 12) 关闭监听后 stop() 幂等。
        do {
            channel.stop()
            channel.stop()
            checks.check(true, "C12 stop 幂等")
        }

        // 13) 执行前取消竞态（主代理真实阻断复现）：请求已通过分类并排队到 MainActor
        //     （accept 线程已抓授权快照）后，revoke 必须先于任何 handler 副作用。把主
        //     actor 同步占住、让请求排队，再 revoke，随后放行 —— 排队请求必须在真正
        //     调用 handler 的 actor 边界因快照不再有效而被拒绝，0 次 handler。
        do {
            let raceLog = ResidentDSHHostCallLog()
            let calls = MainActorCallCounter()
            let raceChannel = try ResidentDSHHostToolsChannel.start(configuration: .init(
                scope: "race", worldID: "race-1",
                registrations: try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas),
                handler: { request in
                    calls.increment()
                    raceLog.append(request.canonicalName, callID: request.callID, argumentsJSON: request.argumentsJSON)
                    return ResidentDSHHostToolReply(resultJSON: try! JSONSerialization.data(withJSONObject: ["ok": true]), isError: false)
                }))
            defer { raceChannel.stop() }
            let raceGrant = ResidentDSHHostSupportSchema.object(try Data(contentsOf: raceChannel.grantFileURL))
            let raceSecret = raceGrant?["secret"] as? String ?? ""
            let started = DispatchSemaphore(value: 0)
            let clientDone = DispatchSemaphore(value: 0)
            let clientBox = ClientResultBox()
            Thread.detachNewThread {
                started.signal()
                clientBox.set(residentDSHHostClientCall(
                    socketPath: raceChannel.socketPath, secret: raceSecret,
                    name: "gmgn_read_wish_generation", arguments: [:],
                    callID: "queued-before-revoke"))
                clientDone.signal()
            }
            syncWait(started)
            // 主 actor 同步占住（usleep）：accept 线程在此期间完成分类并排队 handler；
            // handler 只能等主 actor 放行后运行 —— 而放行前先执行了 revoke。
            usleep(300_000)
            raceChannel.revoke()
            await asyncWait(clientDone, timeout: .now() + 5)
            checks.expectEqual(calls.current, 0, "C13 revoke 后排队调用零执行（执行前取消）")
            checks.expectEqual(
                (clientBox.value.payload?["error"] as? [String: Any])?["code"] as? String,
                "grant_revoked", "C13 排队调用被 grant_revoked 拒绝")
            checks.check(raceLog.count == 0, "C13 宿主日志零执行")
        }

        // 14) revoke 之后马上 re-arm（新 secret/新授权代）也不让旧排队请求借新授权
        //     通过：旧请求持有一轮前的授权快照，执行前复核必须拒绝；随后用本轮新
        //     secret 发起的新调用则正常执行一次（新轮仍可用）。
        do {
            let roundLog = ResidentDSHHostCallLog()
            let calls = MainActorCallCounter()
            let roundChannel = try ResidentDSHHostToolsChannel.start(configuration: .init(
                scope: "race", worldID: "race-1",
                registrations: try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas),
                handler: { request in
                    calls.increment()
                    roundLog.append(request.canonicalName, callID: request.callID, argumentsJSON: request.argumentsJSON)
                    return ResidentDSHHostToolReply(resultJSON: try! JSONSerialization.data(withJSONObject: ["ok": true]), isError: false)
                }))
            defer { roundChannel.stop() }
            let roundGrant = ResidentDSHHostSupportSchema.object(try Data(contentsOf: roundChannel.grantFileURL))
            let oldSecret = roundGrant?["secret"] as? String ?? ""
            let started = DispatchSemaphore(value: 0)
            let clientDone = DispatchSemaphore(value: 0)
            let clientBox = ClientResultBox()
            Thread.detachNewThread {
                started.signal()
                clientBox.set(residentDSHHostClientCall(
                    socketPath: roundChannel.socketPath, secret: oldSecret,
                    name: "gmgn_read_wish_generation", arguments: [:],
                    callID: "queued-before-rearm"))
                clientDone.signal()
            }
            syncWait(started)
            usleep(300_000) // 请求已分类排队
            roundChannel.revoke()
            try roundChannel.arm(worldRevision: 99) // 新一轮授权：新代 + 新 secret
            await asyncWait(clientDone, timeout: .now() + 5)
            checks.expectEqual(calls.current, 0, "C14 revoke+re-arm 后旧排队调用零执行（不借新授权）")
            checks.expectEqual(
                (clientBox.value.payload?["error"] as? [String: Any])?["code"] as? String,
                "grant_revoked", "C14 旧排队调用仍被拒绝（不借新授权）")
            // 本轮新 secret 的调用正常执行。
            let newGrant = ResidentDSHHostSupportSchema.object(try Data(contentsOf: roundChannel.grantFileURL))
            let newSecret = newGrant?["secret"] as? String ?? ""
            checks.check(newSecret != oldSecret, "C14 re-arm 轮换 secret")
            let fresh = await runClient {
                residentDSHHostClientCall(socketPath: roundChannel.socketPath, secret: newSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "fresh-after-rearm")
            }
            checks.expectEqual(fresh.payload?["ok"] as? Bool, true, "C14 新轮调用成功")
            checks.expectEqual(calls.current, 1, "C14 新轮恰好执行一次")
        }

        // 15a) 执行中请求的取消语义：请求已越过执行前复核、handler 正在执行时 revoke，
        //     该次执行不被中断，完成并回执；后续新请求被拒（取消只作用于尚未开始副
        //     作用的部分 —— 预执行取消 0 次 handler）。
        do {
            let execLog = ResidentDSHHostCallLog()
            let calls = MainActorCallCounter()
            let execStarted = DispatchSemaphore(value: 0)
            let execChannel = try ResidentDSHHostToolsChannel.start(configuration: .init(
                scope: "race", worldID: "race-1",
                registrations: try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas),
                handler: { request in
                    calls.increment()
                    execLog.append(request.canonicalName, callID: request.callID, argumentsJSON: request.argumentsJSON)
                    execStarted.signal() // 已越过执行前复核、副作用开始
                    // 给出确定性的「执行中」窗口，供编排线程在其中 revoke。
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    return ResidentDSHHostToolReply(resultJSON: try! JSONSerialization.data(withJSONObject: ["ok": true, "inFlight": true]), isError: false)
                }))
            defer { execChannel.stop() }
            let execGrant = ResidentDSHHostSupportSchema.object(try Data(contentsOf: execChannel.grantFileURL))
            let execSecret = execGrant?["secret"] as? String ?? ""
            let clientDone = DispatchSemaphore(value: 0)
            let clientBox = ClientResultBox()
            Thread.detachNewThread {
                clientBox.set(residentDSHHostClientCall(
                    socketPath: execChannel.socketPath, secret: execSecret,
                    name: "gmgn_read_wish_generation", arguments: [:],
                    callID: "inflight-before-revoke"))
                clientDone.signal()
            }
            // 编排线程：等 handler 真正开始后，在其 600ms 执行窗口内 revoke。
            Thread.detachNewThread {
                _ = execStarted.wait(timeout: .now() + 5)
                usleep(80_000)
                execChannel.revoke()
            }
            await asyncWait(clientDone, timeout: .now() + 5)
            checks.expectEqual(clientBox.value.payload?["ok"] as? Bool, true, "C15a 执行中请求完成并回执")
            checks.expectEqual(calls.current, 1, "C15a 执行中请求恰执行一次")
            checks.expectEqual(
                ((clientBox.value.payload?["data"] as? [String: Any])?["inFlight"] as? Bool),
                true, "C15a 回执来自该次执行")
            // 撤销后的新请求拒绝、零执行。
            let refused = await runClient {
                residentDSHHostClientCall(socketPath: execChannel.socketPath, secret: execSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "after-revoke")
            }
            checks.expectEqual((refused.payload?["error"] as? [String: Any])?["code"] as? String, "grant_revoked", "C15a revoke 后新请求拒绝")
            checks.expectEqual(calls.current, 1, "C15a revoke 后零新增执行")
        }

        // 15b) stop() 唤醒等待中的排队 handler：请求已分类排队、主 actor 仍被占住
        //     （handler 尚未运行）时 stop() —— box 等待有界退出、客户端尽快收到 EOF、
        //     handler 零执行、通道不可再 arm / 新连接无回复。
        do {
            let stopLog = ResidentDSHHostCallLog()
            let calls = MainActorCallCounter()
            let stopRace = try ResidentDSHHostToolsChannel.start(configuration: .init(
                scope: "race", worldID: "race-1",
                registrations: try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas),
                handler: { request in
                    calls.increment()
                    stopLog.append(request.canonicalName, callID: request.callID, argumentsJSON: request.argumentsJSON)
                    return ResidentDSHHostToolReply(resultJSON: try! JSONSerialization.data(withJSONObject: ["ok": true]), isError: false)
                }))
            let stopGrant = ResidentDSHHostSupportSchema.object(try Data(contentsOf: stopRace.grantFileURL))
            let stopSecret = stopGrant?["secret"] as? String ?? ""
            let started = DispatchSemaphore(value: 0)
            let clientDone = DispatchSemaphore(value: 0)
            let clientBox = ClientResultBox()
            Thread.detachNewThread {
                started.signal()
                clientBox.set(residentDSHHostClientCall(
                    socketPath: stopRace.socketPath, secret: stopSecret,
                    name: "gmgn_read_wish_generation", arguments: [:],
                    callID: "queued-before-stop"))
                clientDone.signal()
            }
            syncWait(started)
            usleep(300_000) // 请求已分类排队、主 actor 仍被占住（handler 未运行）
            // 排队请求的 box 等待必须被 stop() 有界唤醒：客户端应尽快收到 EOF，而不是
            // 永久等待。stop 在后台线程执行（主 actor 被占住、无法在 main 里同步停）。
            Thread.detachNewThread { stopRace.stop() }
            // 主 actor 保持占住（同步限时等待）：期间排队 handler 不能运行；若客户端在
            // 有界时间内返回（stop 唤醒 box 等待、连接线程退出），说明等待不是永久 retain。
            let woke = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                _ = clientDone.wait(timeout: .now() + 3)
                woke.signal()
            }
            let stopWaitBegan = Date()
            syncWait(woke, timeout: .now() + 6)
            let stopWaitElapsed = Date().timeIntervalSince(stopWaitBegan)
            checks.check(clientBox.value.error != nil,
                         "C15b stop() 有界唤醒等待中的排队调用（客户端已返回，未永久阻塞；\(stopWaitElapsed)s）")
            checks.check(stopWaitElapsed < 6, "C15b stop 唤醒在有界时间内（\(stopWaitElapsed)s）")
            checks.check(clientBox.value.payload == nil && clientBox.value.error != nil,
                         "C15b stop 后排队调用收到 EOF（无回执）")
            try await Task.sleep(nanoseconds: 200_000_000)
            checks.expectEqual(calls.current, 0, "C15b stop 后排队调用零执行")
            // 通道已停止：arm 抛错、新连接无回复。
            do { try stopRace.arm(worldRevision: nil); checks.check(false, "C15b stop 后 arm 必须抛错") }
            catch ResidentDSHHostToolsError.notStarted { checks.check(true, "C15b stop 后 arm 抛 notStarted") }
            catch { checks.check(false, "C15b stop 后 arm 抛错类型不符") }
            let afterStop = await runClient {
                residentDSHHostClientCall(socketPath: stopRace.socketPath, secret: stopSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "after-stop")
            }
            checks.check(afterStop.payload == nil, "C15b stop 后新连接无回复")
            checks.expectEqual(calls.current, 0, "C15b stop 后零执行")
            stopRace.stop() // 幂等回收
        }

        // 16) 局部挂死客户端不堵死其它调用；并发上限有界（超出立即关闭而不是无限排队）。
        do {
            let stuckLog = ResidentDSHHostCallLog()
            let stuckChannel = try ResidentDSHHostToolsChannel.start(configuration: .init(
                scope: "race", worldID: "race-1",
                registrations: try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas),
                handler: residentDSHHostToolsTestHandler(log: stuckLog, scope: "world.cabin")))
            defer { stuckChannel.stop() }
            let stuckGrant = ResidentDSHHostSupportSchema.object(try Data(contentsOf: stuckChannel.grantFileURL))
            let stuckSecret = stuckGrant?["secret"] as? String ?? ""
            // 三个只连不发的挂死客户端。
            var stuck: [Int32] = []
            for _ in 0..<3 {
                let fd = rawConnect(path: stuckChannel.socketPath)
                if fd >= 0 { stuck.append(fd) }
                usleep(50_000)
            }
            checks.expectEqual(stuck.count, 3, "C16 三个挂死客户端已连上")
            // 挂死期间，正常调用仍被服务（独立连接线程，不堵死后续调用）。
            let healthy = await runClient {
                residentDSHHostClientCall(socketPath: stuckChannel.socketPath, secret: stuckSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "while-stuck")
            }
            checks.expectEqual(healthy.payload?["ok"] as? Bool, true, "C16 挂死客户端不堵死正常调用")
            checks.expectEqual(stuckLog.count, 1, "C16 正常调用执行一次")
            // 并发上限：再填满剩余连接槽后，超出的新连接被立即关闭（客户端快速返回，
            // 无回执）而不是无限排队。
            var extra: [Int32] = []
            for _ in 0..<6 {
                let fd = rawConnect(path: stuckChannel.socketPath)
                if fd >= 0 { extra.append(fd) }
                usleep(50_000)
            }
            let start = Date()
            let overflow = await runClient {
                residentDSHHostClientCall(socketPath: stuckChannel.socketPath, secret: stuckSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "overflow")
            }
            let overflowElapsed = Date().timeIntervalSince(start)
            checks.check(overflow.payload == nil || (overflow.payload?["ok"] as? Bool) == false,
                         "C16 并发超限调用被快速关闭（无成功回执）")
            checks.check(overflowElapsed < 5, "C16 并发超限调用有界返回（\(overflowElapsed)s）")
            checks.expectEqual(stuckLog.count, 1, "C16 超限调用零执行")
            for fd in stuck + extra { if fd >= 0 { close(fd) } }
            // 全部挂死客户端断开后，正常调用恢复可用。
            try await Task.sleep(nanoseconds: 150_000_000)
            let recovered = await runClient {
                residentDSHHostClientCall(socketPath: stuckChannel.socketPath, secret: stuckSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "after-unstick")
            }
            checks.expectEqual(recovered.payload?["ok"] as? Bool, true, "C16 挂死断开后通道恢复可用")
            checks.expectEqual(stuckLog.count, 2, "C16 恢复后正常执行")
        }

        // 17) 跨轮可重绑定 handler（ACP 持久会话复用同一 runtime/通道）：
        //     通道只委托到 ResidentDSHHostToolsBinding；每轮 arm 前 bind 当前轮
        //     worldTools —— 不闭包捕获第一轮已取消的 tools。未绑定/清空后调用诚实拒绝。
        do {
            let bindLog = ResidentDSHHostCallLog()
            let binding = ResidentDSHHostToolsBinding()
            let bindChannel = try ResidentDSHHostToolsChannel.start(configuration: .init(
                scope: "race", worldID: "race-1",
                registrations: try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas),
                handler: binding.channelHandler()))
            defer { bindChannel.stop() }
            func grantSecret() throws -> String {
                let object = ResidentDSHHostSupportSchema.object(try Data(contentsOf: bindChannel.grantFileURL))
                return object?["secret"] as? String ?? ""
            }
            // 未绑定：请求会通过授权闸但执行者未绑定 → 诚实工具错误、宿主零调用。
            let unboundSecret = try grantSecret()
            let unbound = await runClient {
                residentDSHHostClientCall(socketPath: bindChannel.socketPath, secret: unboundSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "unbound")
            }
            checks.expectEqual(unbound.payload?["ok"] as? Bool, false, "C17 未绑定 handler 返回工具错误")
            checks.expectEqual((unbound.payload?["error"] as? [String: Any])?["code"] as? String, "tool_error", "C17 未绑定错误 code=tool_error")
            checks.expectEqual(bindLog.count, 0, "C17 未绑定不触碰任何 worldTools")
            // 第一轮绑定 → 执行该轮 handler。
            let firstLog = ResidentDSHHostCallLog()
            binding.bind(residentDSHHostToolsTestHandler(log: firstLog, scope: "round-1"))
            let first = await runClient {
                residentDSHHostClientCall(socketPath: bindChannel.socketPath, secret: unboundSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "round1")
            }
            checks.expectEqual(first.payload?["ok"] as? Bool, true, "C17 第一轮绑定执行成功")
            checks.expectEqual(firstLog.count, 1, "C17 第一轮 handler 恰执行一次")
            // revoke + re-arm 后绑定第二轮 handler（模拟新一轮 worldTools）→ 旧绑定不再被调用。
            bindChannel.revoke()
            try bindChannel.arm(worldRevision: 2)
            let secondSecret = try grantSecret()
            let secondLog = ResidentDSHHostCallLog()
            binding.bind(residentDSHHostToolsTestHandler(log: secondLog, scope: "round-2"))
            let second = await runClient {
                residentDSHHostClientCall(socketPath: bindChannel.socketPath, secret: secondSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "round2")
            }
            checks.expectEqual(second.payload?["ok"] as? Bool, true, "C17 第二轮绑定执行成功")
            checks.expectEqual(secondLog.count, 1, "C17 第二轮 handler 执行一次")
            checks.expectEqual(firstLog.count, 1, "C17 旧轮（第一轮）handler 不被新轮调用")
            // 会话关闭：clear 后即使授权仍 armed 也诚实拒绝，不执行已取消轮的 tools。
            binding.clear()
            let afterClear = await runClient {
                residentDSHHostClientCall(socketPath: bindChannel.socketPath, secret: secondSecret, name: "gmgn_read_wish_generation", arguments: [:], callID: "after-clear")
            }
            checks.expectEqual(afterClear.payload?["ok"] as? Bool, false, "C17 clear 后调用被拒（handler_unbound）")
            checks.expectEqual(bindLog.count, 0, "C17 clear 后零 worldTools 调用")
        }

        print("\(checks.failures.isEmpty ? "PASS" : "FAIL"): \(checks.passed) resident DSH host-tools channel checks, \(checks.failures.count) failures")
        exit(checks.failures.isEmpty ? 0 : 1)
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
let productionBridge = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift").path
let productionChannel = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift").path
let supportFile = root.appendingPathComponent("tools/resident-dsh-host-tools-support.swift").path
// 编译门与主代理验收命令一致：`-swift-version 6 -parse-as-library` 真实编译（含链接），
// 再运行该 Swift 6 二进制。默认语言模式或仅 -typecheck 不能替代。
compile.arguments = ["-swift-version", "6", "-parse-as-library", "-j1", root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift").path, productionBridge, productionChannel, supportFile, main.path, "-o", binary.path]
compile.currentDirectoryURL = work
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("COMPILE FAILED (exit \(compile.terminationStatus))")
    exit(compile.terminationStatus)
}
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
let testExit = test.terminationStatus
print("swift6 (-swift-version 6) compile+run exit=\(testExit)")
exit(testExit == 0 ? 0 : 1)
