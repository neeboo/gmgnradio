//
//  ResidentDSHHostToolsBridge.swift
//  GMGNRadio
//
//  居民 DSH 的「真实原生宿主工具通道」（2026-09-08 协议修复第二轮）。
//
//  解决的问题：第一轮的文本信封把 agent 输出当函数调用 API 响应，导致正常正文被
//  判协议错误、空间工具实际未被调用。本文件实现真正的 DSH 原生工具注册与宿主
//  调用链：
//
//    · 宿主把「本轮正式工具」（worldTools schemasJSON，canonical 原名）注册进真实
//      DSH：应用侧生成一个私有、仅 0600/0700 的 JS 插件（gmgn-host-tools），通过
//      现有的 `--patch` insert 机制挂进 headless/ACP composition；插件在 DSH 进程内
//      `ctx.tools.register(...)` 原生注册（schema 自动进入模型工具列表）。
//    · 模型在 DSH 里**原生函数调用** gmgn_* 工具 → DSH 工具运行时派发到插件
//      execute → 插件经**受限本地 IPC**（私有目录内 Unix domain socket + 每轮随机
//      secret）把 {callId, name, arguments} 送回宿主 → 宿主做「名称边界 + 原 schema
//      复核 + 每轮/世界授权闸」后调用本轮 worldTools（tools.call）→ 规范 JSON 结果
//      经 IPC 回到插件 execute → DSH agent loop 在同一运行里把结果回灌模型并继续，
//      直到真实 final 正文。整个过程中正文永远是正文，宿主绝不解析自然语言成动作。
//    · 每轮授权不跨轮复用：取消即撤销（grant 文件删除 + secret 轮换 + 闸置假），
//      迟到/未知/未授权调用一律拒绝；保留 worldTools 自身的权限/租约/校验。
//
//  安全面：不新增常驻 daemon/通用框架/文件/Shell/其它代理能力；敏感凭据只在进程
//  内存与本目录私有文件（0600）里，不写日志、不落 UserDefaults。插件源码内嵌在
//  本文件（与既有 dshInteractiveBudgetPlugin 同模式），运行期写入私有目录。
//
//  本文件自包含（仅 Foundation + Darwin），可被 tools/* 离线 swiftc 直接编译运行；
//  复用了 ResidentDSHAgentToolBridge.swift 的清单/原 schema 校验/裁决类型
//  （ResidentDSHFormalToolRegistry / ResidentDSHAgentToolCallClassifier /
//   ResidentDSHOriginalSchemaValidator）。

import Foundation
import Darwin

// MARK: - Public errors

/// 宿主工具桥接错误的脱敏诊断边界。
///
/// 用户文案只允许固定分类；绝对路径、errno、原始 stderr 等内部原因只保留在
/// 经过边界清洗的 `diagnostic` 里（供日志与排障），绝不进入 `errorDescription`。
enum ResidentToolDiagnosticRedaction {
    static let maximumLength = 240

    /// 把绝对路径替换成 `<path>`，压平换行与控制字符，并限长。
    static func redact(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: #"/[^\s"'`;,\)\]]+"#, with: "<path>", options: .regularExpression
        )
        text = String(text.unicodeScalars.map { scalar -> Character in
            scalar.value < 0x20 || scalar.value == 0x7F ? " " : Character(scalar)
        })
        if text.count > maximumLength {
            text = String(text.prefix(maximumLength)) + "…"
        }
        return text
    }
}

public enum ResidentDSHHostToolsError: Error, LocalizedError, Equatable {
    case malformedToolSet(String)
    case invalidConfiguration(String)
    case startupFailed(String)
    case notStarted

    /// 固定分类的用户文案：只说发生了什么与下一步。绝不插值 `reason`
    /// （可能含私有目录路径、socket 路径、errno 或原始诊断）。
    public var errorDescription: String? {
        switch self {
        case .malformedToolSet:
            "本轮世界工具清单无效，这次空间操作已停止。请重新发送这条消息。"
        case .invalidConfiguration:
            "本轮空间工具通道配置无效，这次空间操作已停止。请重新发送这条消息。"
        case .startupFailed:
            "空间工具通道启动失败，本轮空间操作没有执行。请重新发送；若反复出现，请重启应用。"
        case .notStarted:
            "空间工具通道尚未就绪，请重新发送这条消息。"
        }
    }

    /// 诊断码 + 脱敏原因；只给日志，绝不进入用户文案。
    public var diagnostic: String {
        switch self {
        case let .malformedToolSet(reason):
            "dsh_host_tools/malformed_tool_set: \(ResidentToolDiagnosticRedaction.redact(reason))"
        case let .invalidConfiguration(reason):
            "dsh_host_tools/invalid_configuration: \(ResidentToolDiagnosticRedaction.redact(reason))"
        case let .startupFailed(reason):
            "dsh_host_tools/startup_failed: \(ResidentToolDiagnosticRedaction.redact(reason))"
        case .notStarted:
            "dsh_host_tools/not_started"
        }
    }
}

// MARK: - Formal tool registration (parsed from world schemasJSON)

/// 一个正式世界工具在原生通道里的注册描述。`canonicalName` 是工具原名
/// （如 read_wish_generation，无 gmgn_ 前缀）；`declaredName` 是对模型暴露的
/// `gmgn_<canonical>` 名字。
public struct ResidentDSHHostToolRegistration: Sendable, Equatable {
    public let canonicalName: String
    public let declaredName: String
    public let description: String
    /// 工具原参数 schema（canonical 合同，无前缀）的 JSON 文本。
    public let originalSchemaJSON: Data

    public init(canonicalName: String, declaredName: String, description: String, originalSchemaJSON: Data) {
        self.canonicalName = canonicalName
        self.declaredName = declaredName
        self.description = description
        self.originalSchemaJSON = originalSchemaJSON
    }
}

/// 解析 worldTools.schemasJSON（条目 {name, description, inputSchema}）为正式注册
/// 集合。任何畸形/重复/带前缀名字都 fail-closed。
public enum ResidentDSHHostToolSet {
    /// DSH 函数名约束（与 mcp-client 的 publicToolName 同源）与 gmgn_ 前缀长度预算。
    static let maximumNameLength = 64
    public static let declaredPrefix = "gmgn_"

    public static func parse(schemasJSON: Data) throws -> [ResidentDSHHostToolRegistration] {
        guard let root = try? JSONSerialization.jsonObject(with: schemasJSON),
              let entries = root as? [[String: Any]] else {
            throw ResidentDSHHostToolsError.malformedToolSet("schemasJSON 必须是 JSON 数组")
        }
        var seenDeclared = Set<String>()
        var seenCanonical = Set<String>()
        var result: [ResidentDSHHostToolRegistration] = []
        for entry in entries {
            guard let name = entry["name"] as? String, !name.isEmpty,
                  !name.hasPrefix(declaredPrefix) else {
                throw ResidentDSHHostToolsError.malformedToolSet("工具缺少合法 canonical 名")
            }
            let declared = declaredPrefix + name
            guard declared.count <= maximumNameLength else {
                throw ResidentDSHHostToolsError.malformedToolSet("工具暴露名超过 64 字符：\(declared)")
            }
            guard declared.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }) else {
                throw ResidentDSHHostToolsError.malformedToolSet("工具名含不允许的字符：\(declared)")
            }
            guard !seenDeclared.contains(declared), !seenCanonical.contains(name) else {
                throw ResidentDSHHostToolsError.malformedToolSet("工具重复：\(name)")
            }
            let description = entry["description"] as? String ?? ""
            guard let inputSchema = entry["inputSchema"],
                  JSONSerialization.isValidJSONObject(inputSchema) else {
                throw ResidentDSHHostToolsError.malformedToolSet("工具 \(name) 缺少合法 inputSchema")
            }
            let schemaData: Data
            do {
                schemaData = try JSONSerialization.data(withJSONObject: inputSchema, options: [.sortedKeys])
            } catch {
                throw ResidentDSHHostToolsError.malformedToolSet("工具 \(name) 的 inputSchema 无法序列化")
            }
            seenDeclared.insert(declared)
            seenCanonical.insert(name)
            result.append(ResidentDSHHostToolRegistration(
                canonicalName: name,
                declaredName: declared,
                description: description,
                originalSchemaJSON: schemaData
            ))
        }
        return result
    }
}

// MARK: - Wire payload types

/// 一次到达宿主的工具调用（已通过名称边界与参数校验的形态）。
public struct ResidentDSHHostToolRequest: Sendable, Equatable {
    public let callID: String
    public let canonicalName: String
    public let argumentsJSON: Data
    public init(callID: String, canonicalName: String, argumentsJSON: Data) {
        self.callID = callID
        self.canonicalName = canonicalName
        self.argumentsJSON = argumentsJSON
    }
}

/// 宿主执行者（生产 = ResidentConversationTools.call）的规范回执。
public struct ResidentDSHHostToolReply: Sendable, Equatable {
    public let resultJSON: Data
    public let isError: Bool
    /// 原生图片回执：非 nil 时插件会尝试经 DSH attachments 作模型可见图片内容；
    /// 无法准入时退化为诊断文本（图片字节绝不进入正文 JSON）。
    public let imagePNGData: Data?

    public init(resultJSON: Data, isError: Bool, imagePNGData: Data? = nil) {
        self.resultJSON = resultJSON
        self.isError = isError
        self.imagePNGData = imagePNGData
    }
}

// MARK: - Wire framing helpers (newline-delimited JSON over UDS)

enum ResidentDSHHostWire {
    static let protocolVersion = 1
    static let maximumFrameBytes = 2 * 1_048_576

    static func object(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    static func jsonData(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// 读一行（到 \n，含上限），返回去掉结尾换行的帧。
    static func readFrame(from fd: Int32, maximumBytes: Int) -> Data? {
        var buffer = Data()
        var byte = 0 as UInt8
        while buffer.count <= maximumBytes {
            let count = read(fd, &byte, 1)
            if count <= 0 { return nil }
            if byte == 0x0A { return buffer }
            buffer.append(byte)
        }
        return nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var written = 0
        let bytes = [UInt8](data)
        while written < bytes.count {
            let count = write(fd, Array(bytes[written...]), bytes.count - written)
            if count <= 0 { return false }
            written += count
        }
        return true
    }
}

// MARK: - Resident DSH host-tools JS plugin source

/// 真实 DSH 原生工具插件（gmgn-host-tools）源码。运行期写入私有目录并以
/// `--patch` 的 insert 行加载；插件在 DSH 进程内 `ctx.tools.register` 原生注册
/// 宿主本轮正式工具，execute 经私有 UDS + 每轮 secret 回宿主，宿主复核后执行
/// worldTools，规范结果回到同一 DSH 运行继续。
///
/// 插件每次 execute 都重读 grant 文件：授权以「调用时」快照为准——取消/世界切换
/// 即撤销（文件删除或 state 非 armed 时拒绝），每轮 secret 不跨轮复用；未知工具/
/// 非法参数由宿主在 IPC 侧拒绝。正文永不产生动作。
public enum ResidentDSHHostToolsPlugin {
    public static let moduleID = "gmgn-host-tools"
    public static let filename = "gmgn-host-tools.mjs"
    public static let grantFilename = "gmgn-host-tools.grant.json"
    public static let socketFilename = "gmgn-host-tools.sock"

    public static let source = #"""
    import net from 'node:net'
    import fs from 'node:fs'
    import { fileURLToPath } from 'node:url'

    export const name = 'gmgn-host-tools'
    export const inject = ['tools']

    // grant 文件与插件同目录（宿主通道自建私有目录）：不依赖插件 config，
    // 便于 `--patch`/composition 只以 name 挂载并继续通过 `--dump-config` 认证。
    const bootstrapPath = fileURLToPath(new URL('gmgn-host-tools.grant.json', import.meta.url))

    function readGrant(path) {
      let raw
      try { raw = fs.readFileSync(path, 'utf8') } catch (_) { return null }
      try { return JSON.parse(raw) } catch (_) { return null }
    }

    function rpc(socketPath, secret, payload, signal) {
      return new Promise((resolve, reject) => {
        const socket = net.connect(socketPath)
        let settled = false
        let buffer = Buffer.alloc(0)
        const deadline = setTimeout(onTimeout, 120000)
        function finish(err, value) {
          if (settled) return
          settled = true
          clearTimeout(deadline)
          if (signal && typeof signal.removeEventListener === 'function') signal.removeEventListener('abort', onAbort)
          socket.destroy()
          if (err) reject(err); else resolve(value)
        }
        function onTimeout() { finish(new Error('gmgn-host-tools: host call timed out')) }
        function onAbort() { finish(new Error('gmgn-host-tools: host call aborted')) }
        if (signal && typeof signal.addEventListener === 'function') {
          if (signal.aborted) { onAbort(); return }
          signal.addEventListener('abort', onAbort, { once: true })
        }
        socket.on('connect', function () {
          const body = JSON.stringify({ v: 1, secret: secret, callId: payload.callId, name: payload.name, arguments: payload.arguments || {} })
          socket.write(body + '\n')
        })
        socket.on('data', function (chunk) {
          buffer = Buffer.concat([buffer, chunk])
          const newline = buffer.indexOf(10)
          if (newline < 0) {
            if (buffer.length > 8388608) finish(new Error('gmgn-host-tools: oversized host reply'))
            return
          }
          const line = buffer.subarray(0, newline).toString('utf8')
          let parsed
          try { parsed = JSON.parse(line) } catch (_) { finish(new Error('gmgn-host-tools: malformed host reply')); return }
          finish(null, parsed)
        })
        socket.on('error', function (error) {
          finish(new Error('gmgn-host-tools: host connection failed: ' + String((error && error.message) || error)))
        })
        socket.on('close', function () {
          finish(new Error('gmgn-host-tools: host closed connection before reply'))
        })
      })
    }

    async function admitImage(ctx, exec, image) {
      const attachments = ctx && typeof ctx.get === 'function' ? ctx.get('attachments') : null
      if (!attachments || typeof attachments.saveImages !== 'function') throw new Error('no attachment store mounted')
      const llm = ctx && typeof ctx.get === 'function' ? ctx.get('llm') : null
      let routed = null
      try {
        routed = exec && exec.agent && exec.agent.session && typeof exec.agent.session.requestHeader === 'function' ? exec.agent.session.requestHeader() : null
      } catch (_) { routed = null }
      const options = exec && exec.agent && exec.agent.options ? exec.agent.options : null
      const config = routed && routed.config ? routed.config : null
      const provider = config && config.provider ? config.provider : (options ? options.provider : null)
      const model = config && config.model ? config.model : (options ? options.model : null)
      if (!provider || !model || !llm || typeof llm.resolveModelInfo !== 'function') throw new Error('model route unavailable')
      let info
      try {
        info = await llm.resolveModelInfo(provider, model, exec && exec.signal ? exec.signal : undefined)
      } catch (_) { throw new Error('model route could not be verified') }
      if (!info || !Array.isArray(info.inputModalities) || !info.inputModalities.includes('image')) throw new Error('model does not declare image input')
      const base64 = String(image.base64 || '')
      const buf = Buffer.from(base64, 'base64')
      if (buf.toString('base64') !== base64) throw new Error('non-canonical image data')
      const mediaType = typeof image.mimeType === 'string' ? image.mimeType : 'image/png'
      const refs = await attachments.saveImages([{ data: buf, mediaType: mediaType }])
      if (!refs || !refs[0]) throw new Error('image admission produced no attachment')
      return [{ type: 'image', attachment: refs[0] }]
    }

    export function apply(ctx, _config) {
      const grant = readGrant(bootstrapPath)
      if (!grant || !Array.isArray(grant.tools)) throw new Error('gmgn-host-tools: bootstrap unreadable at apply')
      const toolsService = ctx.get('tools')
      if (!toolsService) throw new Error('gmgn-host-tools: tools service unavailable')
      const projections = new WeakMap()
      for (const tool of grant.tools) {
        const declared = tool && tool.name
        if (typeof declared !== 'string' || declared.length === 0) throw new Error('gmgn-host-tools: tool missing name')
        const fallbackFor = function renderText(_args, value) {
          const data = value && typeof value === 'object' && 'data' in value ? value.data : value
          const text = typeof data === 'string' ? data : JSON.stringify(data)
          return [{ type: 'text', text: String(text) }]
        }
        const definition = {
          name: declared,
          description: typeof tool.description === 'string' ? tool.description : '',
          parameters: tool.parameters && typeof tool.parameters === 'object' ? tool.parameters : { type: 'object', properties: {} },
          output: {
            schema: {
              type: 'object',
              properties: { ok: { type: 'boolean' }, data: {} },
              required: ['ok'],
              additionalProperties: false
            },
            render: fallbackFor
          },
          async execute(args, exec) {
            const current = readGrant(bootstrapPath)
            if (!current || current.state !== 'armed') throw new Error('gmgn-host-tools: host 授权未生效或已撤销，拒绝执行')
            let allowed = false
            const tools = current.tools && Array.isArray(current.tools) ? current.tools : []
            for (const candidate of tools) {
              if (candidate && candidate.name === declared) { allowed = true; break }
            }
            if (!allowed) throw new Error('gmgn-host-tools: 本轮未开放工具 ' + declared)
            const socketPath = typeof current.socketPath === 'string' ? current.socketPath : null
            const secret = typeof current.secret === 'string' ? current.secret : ''
            if (!socketPath) throw new Error('gmgn-host-tools: bootstrap lacks socket path')
            const callId = exec && typeof exec.callId === 'string' ? exec.callId : ''
            const signal = exec && exec.signal ? exec.signal : null
            const reply = await rpc(socketPath, secret, { callId: callId, name: declared, arguments: args || {} }, signal)
            if (!reply || reply.ok !== true) {
              const error = reply && reply.error
              const message = error && typeof error.message === 'string' ? error.message : 'gmgn-host-tools: host refused the call'
              throw new Error(message)
            }
            const value = { ok: true, data: reply.data === undefined ? null : reply.data }
            const image = reply.image
            if (image && typeof image === 'object' && typeof image.base64 === 'string' && image.base64.length > 0) {
              const fallback = fallbackFor(null, value)
              let content = fallback
              try { content = await admitImage(ctx, exec, image) } catch (_) { content = fallback }
              projections.set(exec, { value: value, fallback: fallback, content: content })
            }
            return value
          }
        }
        definition.finalizeContent = function finalize(exec, result) {
          const projection = projections.get(exec)
          if (!projection) return undefined
          if (result.isError) return undefined
          if (result.value !== projection.value) return undefined
          projections.delete(exec)
          return projection.content
        }
        toolsService.register(definition)
      }
    }
    """#
}

// MARK: - Host channel

/// 宿主侧原生工具通道。负责：
///  1. 在私有目录写插件文件与 grant 文件（0600）、启动 UDS 监听（受 secret 保护）；
///  2. 每轮 arm()：新 secret + state=armed；revoke()/stop()：删除 grant、关闸、撤听；
///  3. 连接处理：secret 校验 → 名称边界 → 原 schema 复核 → 授权闸 →
///     调用宿主 handler（生产 = worldTools.call）→ 规范 JSON 回写。
///
/// 并发与取消语义（2026-09-08 第三轮修复，见
/// docs/plans/evidence/2026-09-08-dsh-agent-tool-bridge.md §5.1）：
///   - 授权以「调用时」快照为准：分类阶段只抓 (authorizationEpoch, secret) 快照，
///     真正调用 handler 前在 **MainActor 边界**用同一把锁重新核验该快照仍等于当前
///     (epoch, secret)。因此已排队的请求若在 revoke() 之后才执行，一律拒绝；revoke
///     再 arm() 会推进 epoch 并轮换 secret，旧请求永远无法借新授权通过。已越过
///     复核、副作用已开始的执行不会被 revoke 中断（完成并回执），取消只作用于
///     「尚未开始副作用」的排队请求 —— 预执行取消保证 0 次 handler。
///   - 单连接由独立线程处理（并发上限 = 4），accept 循环以 poll(200ms) 驱动：
///     一个慢/挂死的客户端只占用自己的线程与有界读超时，不会堵死 accept 或其它
///     调用；连接读写均有 SO_RCVTIMEO/SO_SNDTIMEO 上界。stop() 对已登记 fd
///     shutdown 唤醒阻塞读，accept 线程最迟一个 poll 心跳自行关闭监听 fd 退出，
///     MainActor 等待有 handlerWaitTimeout 上界 —— 不存在永久 retained 的线程。
///   - MainActor 结果经锁+信号量配对的 HostExecutionBox 回传（不是把 var 捕获进
///     @Sendable 闭包），Swift 6 严格并发下无未同步共享。
public final class ResidentDSHHostToolsChannel: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let scope: String
        public let worldID: String
        public let registrations: [ResidentDSHHostToolRegistration]
        /// 生产集成：包装 ResidentConversationTools.call（callID/canonical/args）。
        public let handler: @MainActor @Sendable (ResidentDSHHostToolRequest) async -> ResidentDSHHostToolReply

        public init(
            scope: String,
            worldID: String,
            registrations: [ResidentDSHHostToolRegistration],
            handler: @escaping @MainActor @Sendable (ResidentDSHHostToolRequest) async -> ResidentDSHHostToolReply
        ) {
            self.scope = scope
            self.worldID = worldID
            self.registrations = registrations
            self.handler = handler
        }
    }

    // MARK: State (protected by lock)

    private let lock = NSLock()
    private let configuration: Configuration
    public let directoryURL: URL
    public let pluginFileURL: URL
    public let grantFileURL: URL
    public let socketPath: String

    private var listenerFD: Int32 = -1
    private var currentSecret: String = ""
    private var armed = false
    private var stopped = false
    /// 授权代数：每次 arm()/revoke()/stop() 推进。执行前复核比对捕获的代，
    /// revoke 后再 arm 的新授权绝不向后兼容旧请求。
    private var authorizationEpoch: UInt64 = 0
    /// 当前正在处理的客户端 fd（stop() 对其 shutdown 以唤醒阻塞的 read/write）。
    private var activeClientFDs: [Int32] = []
    /// 并发处理连接的上界；满时新连接立即关闭，不会无界排队/占用线程。
    private let connectionSlots = DispatchSemaphore(value: 4)
    /// true = start(configuration:) 自建的短名临时目录，stop() 整目录删除。
    private let removesDirectoryOnStop: Bool

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 注册集合按 declaredName / canonicalName 索引（start 时构建，只读）。
    private let declaredToCanonical: [String: String]
    private let canonicalToSchemaJSON: [String: Data]

    // MARK: Lifecycle

    /// 启动宿主通道：在系统临时目录下创建**短名**私有目录（0700），写入插件与
    /// grant（0600）、启动 UDS 监听，初始授权为 armed。
    ///
    /// 为什么自己建短目录：AF_UNIX socket 路径上限约 104 字节，而宿主既有私有
    /// 目录（如 `gmgn-resident-<uuid>`）在系统临时根下往往超过该长度；因此 socket
    /// 必须放在短路径下。插件/grant 由 `--patch` overlay 与插件 config 以绝对路径
    /// 引用，不受该限制。stop() 会整目录清理。
    public static func start(configuration: Configuration) throws -> ResidentDSHHostToolsChannel {
        guard !configuration.registrations.isEmpty else {
            throw ResidentDSHHostToolsError.invalidConfiguration("本轮没有正式工具")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory
        let name = "gmgn-dshh-" + Self.randomToken().prefix(8)
        let directoryURL = root.appendingPathComponent(name, isDirectory: true)
        do {
            try manager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ResidentDSHHostToolsError.startupFailed("无法创建私有目录：\(error.localizedDescription)")
        }
        do {
            let channel = try start(configuration: configuration, in: directoryURL)
            return channel
        } catch {
            try? manager.removeItem(at: directoryURL)
            throw error
        }
    }

    private static func start(
        configuration: Configuration,
        in directoryURL: URL,
        removesDirectoryOnStop: Bool
    ) throws -> ResidentDSHHostToolsChannel {
        let pluginURL = directoryURL.appendingPathComponent(ResidentDSHHostToolsPlugin.filename)
        let grantURL = directoryURL.appendingPathComponent(ResidentDSHHostToolsPlugin.grantFilename)
        let socket = directoryURL.appendingPathComponent(ResidentDSHHostToolsPlugin.socketFilename)
        guard socket.path.utf8.count < 100 else {
            throw ResidentDSHHostToolsError.invalidConfiguration("socket 路径过长")
        }
        let manager = FileManager.default
        let channel = ResidentDSHHostToolsChannel(
            configuration: configuration,
            directoryURL: directoryURL,
            pluginFileURL: pluginURL,
            grantFileURL: grantURL,
            socketPath: socket.path,
            removesDirectoryOnStop: removesDirectoryOnStop
        )
        do {
            try Data(ResidentDSHHostToolsPlugin.source.utf8).write(to: pluginURL, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pluginURL.path)
            try channel.startListener()
            try channel.arm(worldRevision: nil)
        } catch {
            // 启动中途失败也必须回收：监听 fd/accept 线程与任何半开连接都要停掉，
            // 否则强引用会一直留住通道。
            channel.stop()
            try? manager.removeItem(at: pluginURL)
            try? manager.removeItem(at: grantURL)
            try? manager.removeItem(at: URL(fileURLWithPath: socket.path))
            throw error
        }
        return channel
    }

    /// 在调用方提供的目录内启动（该目录必须足够短以容纳 AF_UNIX socket；
    /// 生产路径一律用 `start(configuration:)`）。
    public static func start(
        configuration: Configuration,
        in directoryURL: URL
    ) throws -> ResidentDSHHostToolsChannel {
        try start(configuration: configuration, in: directoryURL, removesDirectoryOnStop: false)
    }

    private init(
        configuration: Configuration,
        directoryURL: URL,
        pluginFileURL: URL,
        grantFileURL: URL,
        socketPath: String,
        removesDirectoryOnStop: Bool
    ) {
        self.configuration = configuration
        self.directoryURL = directoryURL
        self.pluginFileURL = pluginFileURL
        self.grantFileURL = grantFileURL
        self.socketPath = socketPath
        self.removesDirectoryOnStop = removesDirectoryOnStop
        var declaredToCanonical: [String: String] = [:]
        var canonicalToSchemaJSON: [String: Data] = [:]
        for registration in configuration.registrations {
            declaredToCanonical[registration.declaredName] = registration.canonicalName
            canonicalToSchemaJSON[registration.canonicalName] = registration.originalSchemaJSON
        }
        self.declaredToCanonical = declaredToCanonical
        self.canonicalToSchemaJSON = canonicalToSchemaJSON
    }

    /// 本轮授权生效：重写 grant 文件（新 secret、state=armed）。每轮调用一次；
    /// 取消/世界切换后由 revoke() 撤销。
    public func arm(worldRevision: UInt64?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw ResidentDSHHostToolsError.notStarted }
        // 新的一轮授权 = 新代 + 新 secret：任何按旧 (epoch, secret) 排队、尚未执行
        // 的请求都过不了 MainActor 边界的执行前复核。
        authorizationEpoch &+= 1
        let secret = Self.randomToken()
        currentSecret = secret
        armed = true
        try writeGrantLocked(secret: secret, armed: true, worldRevision: worldRevision)
    }

    /// 撤销当前授权（取消 / 世界切换 / 会话关闭）：删除 grant 文件并关闸。
    /// 迟到的工具调用（含已握到旧 secret、甚至已通过分类正在排队的请求）一律拒绝。
    public func revoke() {
        lock.lock()
        // 即使 revoke 紧接着 arm，也在代上作废所有在途/排队请求。
        authorizationEpoch &+= 1
        armed = false
        currentSecret = ""
        lock.unlock()
        try? FileManager.default.removeItem(at: grantFileURL)
    }

    /// 停止监听与清理（含私有目录整目录删除）。幂等。监听 fd 由 accept 线程自行
    /// 关闭（单线程所有，避免跨线程 close 与 poll/accept 竞态）；这里只置 stopped、
    /// 推进授权代并 shutdown 活动客户端 fd，唤醒各自阻塞的 read/write/等待线程，
    /// 让它们在各自有界超时内退出 —— 没有任何通道线程会被永久 retain。
    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        authorizationEpoch &+= 1
        armed = false
        currentSecret = ""
        // 在锁内 shutdown：登记/注销都在同一把锁下，shutdown 绝不会命中一个已被
        // 关闭并复用的 fd 号。
        for client in activeClientFDs {
            _ = shutdown(client, SHUT_RDWR)
        }
        lock.unlock()
        if removesDirectoryOnStop {
            try? FileManager.default.removeItem(at: directoryURL)
        } else {
            try? FileManager.default.removeItem(at: grantFileURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketPath))
        }
    }

    // MARK: Grant file writing (lock held)

    private func writeGrantLocked(secret: String, armed: Bool, worldRevision: UInt64?) throws {
        var tools: [[String: Any]] = []
        for registration in configuration.registrations {
            guard let schemaObject = ResidentDSHHostWire.object(registration.originalSchemaJSON) else {
                throw ResidentDSHHostToolsError.invalidConfiguration(
                    "工具 \(registration.canonicalName) 的 schema 无法解析"
                )
            }
            tools.append([
                "name": registration.declaredName,
                "canonical": registration.canonicalName,
                "description": registration.description,
                "parameters": schemaObject,
            ])
        }
        var payload: [String: Any] = [
            "protocol": ResidentDSHHostWire.protocolVersion,
            "state": armed ? "armed" : "idle",
            "secret": secret,
            "round": Self.randomToken(),
            "scope": configuration.scope,
            "worldID": configuration.worldID,
            "socketPath": socketPath,
            "tools": tools,
        ]
        if let worldRevision {
            payload["worldRevision"] = NSNumber(value: worldRevision)
        }
        guard let data = ResidentDSHHostWire.jsonData(payload) else {
            throw ResidentDSHHostToolsError.invalidConfiguration("grant 无法序列化")
        }
        do {
            try data.write(to: grantFileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: grantFileURL.path
            )
            let readBack = try Data(contentsOf: grantFileURL)
            guard readBack == data else {
                throw ResidentDSHHostToolsError.startupFailed("grant 写回校验失败")
            }
        } catch {
            throw ResidentDSHHostToolsError.startupFailed("grant 写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: UDS listener

    private func startListener() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ResidentDSHHostToolsError.startupFailed("无法创建 socket")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let count = min(raw.count, socketPath.utf8.count)
            for (index, byte) in socketPath.utf8.prefix(count).enumerated() {
                raw[index] = byte
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw ResidentDSHHostToolsError.startupFailed("bind 失败：\(detail)")
        }
        guard listen(fd, 8) == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw ResidentDSHHostToolsError.startupFailed("listen 失败：\(detail)")
        }
        // 目录与 socket 仅本进程可访问：目录 0700、socket 0600。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: socketPath)

        lock.lock()
        listenerFD = fd
        stopped = false
        lock.unlock()
        let selfRef = self
        Thread.detachNewThread { selfRef.acceptLoop() }
    }

    /// accept 循环：poll(200ms) 心跳驱动，绝不无界阻塞。stop() 置 stopped 后，
    /// 本线程最迟一个心跳内自行关闭监听 fd 并退出 —— 监听 fd 从创建到关闭始终
    /// 只被这一个线程接触，不存在跨线程 close 与 poll/accept 的竞态。
    private func acceptLoop() {
        lock.lock()
        let listener = listenerFD
        lock.unlock()
        guard listener >= 0 else { return }
        while true {
            lock.lock()
            let isStopped = stopped
            lock.unlock()
            if isStopped {
                close(listener)
                lock.lock()
                if listenerFD == listener { listenerFD = -1 }
                lock.unlock()
                return
            }
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                // 监听 fd 被关闭（本线程之外不应发生）；直接退出，避免忙转。
                return
            }
            if ready == 0 { continue }
            guard descriptor.revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                // 瞬时错误（EMFILE 等）：退避一个心跳后继续，不忙转。
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            spawnConnection(client)
        }
    }

    /// 每个已接受连接由独立线程处理（并发上限 4，用计数信号量控制）：单个慢/挂死
    /// 客户端只占用自己的线程与有界超时，绝不阻塞 accept 或其它调用；上限外的新
    /// 连接立即关闭，避免无界排队。
    private func spawnConnection(_ client: Int32) {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else {
            close(client)
            return
        }
        guard connectionSlots.wait(timeout: .now()) == .success else {
            close(client)
            return
        }
        let selfRef = self
        Thread.detachNewThread {
            defer { selfRef.connectionSlots.signal() }
            selfRef.processConnection(client)
        }
    }

    private func registerClient(_ client: Int32) {
        lock.lock()
        activeClientFDs.append(client)
        lock.unlock()
    }

    private func unregisterClient(_ client: Int32) {
        lock.lock()
        activeClientFDs.removeAll { $0 == client }
        lock.unlock()
    }

    private var isStoppedFlag: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func processConnection(_ client: Int32) {
        registerClient(client)
        defer {
            unregisterClient(client)
            close(client)
        }
        // 单连接有界 I/O：peer 一直不读/不写也只占住自己的线程 ≤ 超时上限；
        // stop() 会 shutdown 已登记 fd，把阻塞中的 read/write 立刻唤醒。
        // SO_NOSIGPIPE：peer 提前关闭时 write 返回 EPIPE 而不是杀死整个进程。
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var receive = timeval(tv_sec: Int(Self.clientReadTimeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))
        var send = timeval(tv_sec: Int(Self.clientWriteTimeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
        guard let frame = ResidentDSHHostWire.readFrame(from: client, maximumBytes: ResidentDSHHostWire.maximumFrameBytes),
              let request = ResidentDSHHostWire.object(frame) else { return }
        guard let replyData = self.authorizeAndExecute(request) else { return }
        _ = ResidentDSHHostWire.writeAll(client, replyData + Data([0x0A]))
    }

    // MARK: Authorization epoch / bounded timeouts

    private static let clientReadTimeout: TimeInterval = 30
    private static let clientWriteTimeout: TimeInterval = 30
    /// 宿主 handler 执行上界（与 JS 插件侧 rpc 120s deadline 对齐）：MainActor 排队
    /// 或执行超过该上界时，连接线程有界退出，绝不永久 retain。
    private static let handlerExecutionTimeout: TimeInterval = 120

    private struct AuthorizationSnapshot: Sendable {
        let epoch: UInt64
        let secret: String
    }

    private struct AcceptedCall: Sendable {
        let callID: String
        let canonicalName: String
        let argumentsJSON: Data
        let authorization: AuthorizationSnapshot
    }

    private enum RequestVerdict {
        case refusal(code: String, message: String)
        case accepted(AcceptedCall)
    }

    /// 授权复核：执行前（MainActor 边界）比对「分类时捕获的同一 (epoch, secret)」
    /// 仍等于当前值。revoke()/stop()/再次 arm() 都会推进 epoch，因此：
    ///   - revoke 之后才轮到执行的排队请求 → 拒绝（0 次 handler）；
    ///   - revoke 后马上 arm 新代 → 旧请求依然无法借新授权通过。
    private func authorizationCurrent(_ snapshot: AuthorizationSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, armed, !currentSecret.isEmpty else { return false }
        return authorizationEpoch == snapshot.epoch && currentSecret == snapshot.secret
    }

    /// 连接线程侧的同步壳：分类在本地完成；真正的 handler 调用永远在 @MainActor
    /// 上执行（`executeOnMainActor` 先复核授权再调用），结果经锁+信号量配对的
    /// HostExecutionBox 回传。等待有 handlerExecutionTimeout 上界；stop 时立即退出。
    private func authorizeAndExecute(_ request: [String: Any]) -> Data? {
        func refusalFrame(_ code: String, _ message: String) -> Data? {
            ResidentDSHHostWire.jsonData([
                "v": ResidentDSHHostWire.protocolVersion,
                "ok": false,
                "error": ["code": code, "message": message],
            ])
        }
        switch classify(request) {
        case let .refusal(code, message):
            return refusalFrame(code, message)
        case let .accepted(call):
            let box = HostExecutionBox()
            Task { @MainActor in
                let outcome = await self.executeOnMainActor(call)
                box.deliver(outcome)
            }
            let deadline = DispatchTime.now() + .seconds(Int(Self.handlerExecutionTimeout))
            switch box.wait(until: deadline, isStopped: { self.isStoppedFlag }) {
            case .delivered:
                switch box.takeOutcome() {
                case let .reply(object):
                    return ResidentDSHHostWire.jsonData(object)
                case let .refusal(code, message):
                    return refusalFrame(code, message)
                case nil:
                    return refusalFrame("transport_failed", "宿主执行者无回执")
                }
            case .stopped:
                // stop() 已 shutdown 本连接：客户端已不在，无需（也无法）回写。
                return nil
            case .timedOut:
                return refusalFrame(
                    "host_execution_timeout",
                    "宿主工具执行超过上界，未确认完成，已放弃该调用"
                )
            }
        }
    }

    /// 真正调用宿主 handler 的 MainActor 边界。**先复核授权再动手**：从这里开始
    /// 才算副作用发生；复核失败（revoke/stop/re-arm 后）绝不执行 handler。
    @MainActor
    private func executeOnMainActor(_ call: AcceptedCall) async -> HostExecutionOutcome {
        guard authorizationCurrent(call.authorization) else {
            return .refusal(code: "grant_revoked", message: "本轮授权已撤销或未生效，拒绝执行")
        }
        let result = await self.configuration.handler(ResidentDSHHostToolRequest(
            callID: call.callID, canonicalName: call.canonicalName, argumentsJSON: call.argumentsJSON
        ))
        return .reply(Self.successResponse(result))
    }

    private func classify(_ request: [String: Any]) -> RequestVerdict {
        guard (request["v"] as? Int) == ResidentDSHHostWire.protocolVersion else {
            return .refusal(code: "protocol_mismatch", message: "宿主工具 IPC 协议版本不匹配")
        }
        // 分类只抓「当前授权代 + secret」快照；它不是执行许可。真正的执行前复核
        // 在 MainActor 边界（executeOnMainActor）用同一快照再做一次。
        lock.lock()
        let snapshot: AuthorizationSnapshot? = (armed && !currentSecret.isEmpty)
            ? AuthorizationSnapshot(epoch: authorizationEpoch, secret: currentSecret)
            : nil
        lock.unlock()
        guard let snapshot, (request["secret"] as? String) == snapshot.secret else {
            return .refusal(code: "grant_revoked", message: "本轮授权已撤销或未生效，拒绝执行")
        }
        guard let callID = request["callId"] as? String, !callID.isEmpty else {
            return .refusal(code: "invalid_call_id", message: "工具调用编号不能为空")
        }
        guard let declaredName = request["name"] as? String, !declaredName.isEmpty else {
            return .refusal(code: "tool_not_allowed", message: "缺少工具名")
        }
        guard let canonical = declaredToCanonical[declaredName] else {
            return .refusal(code: "tool_not_allowed", message: "该名字未在宿主正式工具清单中声明，不会被执行。")
        }
        guard let arguments = request["arguments"] else {
            return .refusal(code: "invalid_arguments", message: "工具参数缺失")
        }
        guard JSONSerialization.isValidJSONObject(arguments),
              let argumentsData = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            return .refusal(code: "invalid_arguments", message: "工具参数必须是合法 JSON")
        }
        guard let schemaData = canonicalToSchemaJSON[canonical] else {
            return .refusal(code: "tool_not_allowed", message: "正式工具缺少原 schema，拒绝执行。")
        }
        switch ResidentDSHOriginalSchemaValidator.validate(
            argumentsJSON: argumentsData, against: schemaData
        ) {
        case let .valid(normalized):
            return .accepted(AcceptedCall(
                callID: callID, canonicalName: canonical, argumentsJSON: normalized,
                authorization: snapshot
            ))
        case let .invalid(reason):
            return .refusal(code: "invalid_arguments", message: "工具参数未通过原 schema 校验：\(reason)")
        case let .schemaUnsupported(reason):
            return .refusal(code: "schema_unsupported", message: "工具原 schema 含宿主校验器不支持的描述，拒绝执行：\(reason)")
        }
    }

    private static func successResponse(_ reply: ResidentDSHHostToolReply) -> [String: Any] {
        let parsedValue = (try? JSONSerialization.jsonObject(with: reply.resultJSON))
            ?? (String(decoding: reply.resultJSON, as: UTF8.self))
        if reply.isError {
            let text = reply.resultJSON.isEmpty
                ? "宿主工具执行失败"
                : String(decoding: reply.resultJSON, as: UTF8.self)
            let bounded = String(text.prefix(2000))
            return [
                "v": protocolVersionValue,
                "ok": false,
                "error": ["code": "tool_error", "message": bounded],
                "data": parsedValue,
            ]
        }
        var response: [String: Any] = [
            "v": protocolVersionValue,
            "ok": true,
            "data": parsedValue,
        ]
        if let png = reply.imagePNGData, !png.isEmpty {
            response["image"] = [
                "mimeType": "image/png",
                "base64": png.base64EncodedString(),
            ]
        }
        return response
    }

    private static let protocolVersionValue = ResidentDSHHostWire.protocolVersion
}

// MARK: - Host execution outcome / result box

/// 一次宿主调用的执行结果：规范回执或执行前复核拒绝（在 @MainActor 上产生，
/// 经 HostExecutionBox 跨隔离域回传）。
private enum HostExecutionOutcome {
    case reply([String: Any])
    case refusal(code: String, message: String)
}

/// 一次宿主调用的结果箱：连接线程等待、@MainActor 任务投递。所有内存访问都在箱内
/// 锁与信号量配对下完成 —— 不用把 `var` 直接捕获进 @Sendable 任务闭包，避免 Swift 6
/// 严格并发下的未同步共享；stop()/超时之后迟到的投递被 finished 守卫丢弃。
private final class HostExecutionBox: @unchecked Sendable {
    enum WaitResult {
        case delivered
        case stopped
        case timedOut
    }

    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outcome: HostExecutionOutcome?
    private var finished = false

    func deliver(_ outcome: HostExecutionOutcome) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        self.outcome = outcome
        lock.unlock()
        semaphore.signal()
    }

    /// 等待投递；每 50ms 检查一次通道是否已停止（stop() 后连接线程尽快退出），
    /// 且整体不超过 deadline —— 等待中的 handler 永不永久 retain 连接线程。
    func wait(until deadline: DispatchTime, isStopped: @escaping () -> Bool) -> WaitResult {
        while true {
            switch semaphore.wait(timeout: .now() + .milliseconds(50)) {
            case .success:
                return .delivered
            case .timedOut:
                if isStopped() { return .stopped }
                if DispatchTime.now() >= deadline { return .timedOut }
            }
        }
    }

    func takeOutcome() -> HostExecutionOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

// MARK: - YAML overlay rows (host-tools plugin insert)

/// 生成供 `--patch` overlay 追加的 host-tools 插件行（insert）。
public enum ResidentDSHHostToolsOverlay {
    /// 把 start() 在私有目录写好的插件文件挂进 composition；grant 由插件以
    /// import.meta.url 同目录解析（`gmgn-host-tools.grant.json`），行内无需 config。
    public static func hostToolsRows(
        pluginFileURL: URL,
        moduleID: String = ResidentDSHHostToolsPlugin.moduleID
    ) -> String {
        """
        - insert:
            - id: \(moduleID)
              name: '\(pluginFileURL.path)'
        """
    }
}

// MARK: - Per-round rebindable host handler

/// 可在轮次间重新绑定的宿主 handler 容器。
///
/// ACP 持久会话跨多轮复用同一 runtime（同一 composition / 插件路径 / 宿主通道）：
/// 通道 Configuration 的 handler 只委托到这个容器一次，Service 每轮 arm() 前
/// `bind(...)` 该轮的 worldTools 调用包装 —— 通道永不闭包捕获「第一轮」的 tools，
/// 每轮执行的始终是**当前轮**绑定的 worldTools（旧轮取消后其 handler 不再被调用）。
/// bind/clear 由锁保护；执行（@MainActor）在锁内取当前 handler。
public final class ResidentDSHHostToolsBinding: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (ResidentDSHHostToolRequest) async -> ResidentDSHHostToolReply

    private let lock = NSLock()
    private var handler: Handler?

    public init() {}

    /// 绑定本轮 handler（每轮 arm 前调用）。旧绑定立即被替换。
    public func bind(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    /// 清空绑定（runtime/会话关闭时调用）。
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    /// 供通道在 @MainActor 上取当前绑定执行；nil 表示本轮未绑定（诚实拒绝）。
    public func currentHandler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    /// 包装成通道 Configuration.handler 用的固定委托闭包：永远解析「当前绑定」，
    /// 未绑定/已清空时返回规范工具错误（不抛、不落日志）。
    public func channelHandler() -> @MainActor @Sendable (ResidentDSHHostToolRequest) async -> ResidentDSHHostToolReply {
        { request in
            guard let handler = self.currentHandler() else {
                let payload = try? JSONSerialization.data(withJSONObject: [
                    "ok": false,
                    "error": ["code": "handler_unbound", "message": "本轮宿主工具执行者未绑定"],
                ])
                return ResidentDSHHostToolReply(
                    resultJSON: payload ?? Data("{\"ok\":false}".utf8), isError: true
                )
            }
            return await handler(request)
        }
    }
}
