//
//  ResidentClaudeToolBridge.swift
//  GMGNRadio
//
//  Claude Code 世界工具的受限 MCP bridge。
//
//  目标：给 Claude Code `--mcp-config` 一个**受限 Node stdio MCP adapter**，让模型能
//  以 MCP tools/list / tools/call 调用「本轮正式世界工具」，同时不引入任何新的全权限
//  通道、shell、文件读写或第二套授权；标准 MCP stdio 仅连接模型进程与 adapter：
//
//    · 复用既有会话级宿主通道 ResidentDSHHostToolsChannel：同一个短名 0700 私有目录、
//      同一个私有 HTTP loopback、同一把每轮随机 token、同一套名称边界 + 原 schema 复核 +
//      授权代（epoch）复核。本文件复用 HTTP 宿主端点、不新增 daemon、不注册 shell/read/write。
//    · adapter 源码在会话启动时写入该私有目录（0600），`--mcp-config` 以绝对路径引用；
//      adapter 只作 MCP↔HTTP 的受限翻译，未在正式 schema 中的名字（含 shell/read/write）
//      在 adapter 侧即被拒绝。
//    · adapter 进程启动时**钉住**当时的 grant 身份（secret + round），之后每次
//      tools/call 前与宿主回包前都重读同目录授权文件（0600，读取有界）并要求身份
//      仍等于钉住值：state 非 armed、身份不符（revoke 后 re-arm 的新 secret/round）、
//      expiresAt 缺失/非有限数/已过 → 本地拒绝。取消 = 宿主删除授权文件并让通道
//      revoke（secret 轮换 + epoch 推进）；旧 adapter 进程绝不借新 secret 复活，
//      迟到的工具结果也绝不回给模型。
//    · 边界有界：stdio 请求行、响应行、文本内容、图片 base64、宿主回包、grant 重读
//      均有上界；tools/call 并发有界（上限 4，超量固定 busy 错误，无无界 Promise）；
//      畸形 JSON / 非法 id 形态 / 非对象 params / null arguments / 超长输入 / 未知方法
//      返回固定 JSON-RPC 错误，绝不回显路径、secret 或异常细节。
//    · 工具结果 JSON → MCP text content；imagePNGData → MCP image content；工具失败
//      经 isError=true 回传（工具自身错误载荷保留，桥自身错误只给固定通用文本）。
//
//  安全面：敏感信息只存在于进程内存与该 0600 私有文件；不写日志、不落 UserDefaults、
//  不读凭据、不扫环境变量。本文件只 import Foundation，复用
//  ResidentDSHAgentToolBridge.swift / ResidentDSHHostToolsBridge.swift 的公开类型
//  （ResidentDSHHostToolRegistration / ResidentDSHHostToolsChannel），可被 tools/*
//  离线 swiftc 与二者一起直接编译运行。
//

import Foundation

// MARK: - Public errors

public enum ResidentClaudeMCPBridgeError: Error, LocalizedError, Equatable {
    case invalidRegistrations(String)
    case forbiddenToolName(String)
    case adapterUnavailable
    case grantWriteFailed
    case sessionStopped

    /// 固定分类的用户文案：绝不插值 `reason`/工具名（可能含路径或原始诊断）。
    public var errorDescription: String? {
        switch self {
        case .invalidRegistrations:
            "工具清单无效，这次操作没有执行。请重新发送。"
        case .forbiddenToolName:
            "这次要用的能力 Claude 不支持，请到设置里换个模型再试。"
        case .adapterUnavailable:
            "Claude 没接上，这次操作没有执行。请检查它是否装好。"
        case .grantWriteFailed:
            "授权没写成功，这次操作没有执行。请重新发送。"
        case .sessionStopped:
            "连接已停止，请重新发送。"
        }
    }

    /// 诊断码 + 脱敏原因；只给日志，绝不进入用户文案。
    public var diagnostic: String {
        switch self {
        case let .invalidRegistrations(reason):
            "claude_mcp/invalid_registrations: \(ResidentToolDiagnosticRedaction.redact(reason))"
        case let .forbiddenToolName(name):
            "claude_mcp/forbidden_tool_name: \(ResidentToolDiagnosticRedaction.redact(name))"
        case .adapterUnavailable:
            "claude_mcp/adapter_unavailable"
        case .grantWriteFailed:
            "claude_mcp/grant_write_failed"
        case .sessionStopped:
            "claude_mcp/session_stopped"
        }
    }
}

// MARK: - Restricted Node stdio MCP adapter

/// 受限 stdio MCP adapter 的生成与常量。adapter 只暴露传入的正式工具 schema，
/// 结构性禁止 shell/read/write 等本机能力。
public enum ResidentClaudeMCPAdapter {
    public static let serverName = "gmgn-resident-tools"
    public static let serverVersion = "1.0.0"
    public static let protocolVersion = "2024-11-05"
    public static let filename = "gmgn-claude-mcp-adapter.mjs"
    public static let grantFilename = "gmgn-claude-mcp.grant.json"
    public static let configFilename = "gmgn-claude-mcp.config.json"

    /// Claude `--allowedTools` 的**逐项精确**放行名：`mcp__<server>__<declaredName>`。
    /// 每个本轮正式工具一条；绝不返回 `mcp__<server>` 这类 server 级宽泛片段
    /// （那等于放行该 server 的全部工具），也绝不放行任何内建联网/本机工具或全局 bypass。
    public static func allowedToolNames(
        registrations: [ResidentDSHHostToolRegistration]
    ) -> [String] {
        registrations.map { "mcp__\(serverName)__\($0.declaredName)" }
    }

    // 有界边界（与 adapter 内常量同源注入）。
    public static let maximumRequestBytes = 1_048_576
    public static let maximumResponseBytes = 2_097_152
    public static let maximumTextBytes = 262_144
    public static let maximumImageBase64Bytes = 1_048_576
    public static let maximumHostReplyBytes = 4_194_304
    public static let maximumGrantBytes = 65_536
    public static let maximumConcurrentToolCalls = 4
    public static let requestTimeoutMilliseconds = 120_000

    /// 永不允许注册的本机能力名（精确匹配；`read_wish_generation` 等正式名不受影响）。
    public static let forbiddenToolNames: Set<String> = [
        "shell", "bash", "sh", "zsh", "fish", "exec", "execute", "run", "run_command",
        "system", "terminal", "process", "subprocess",
        "read", "write", "edit", "patch", "apply_patch", "read_file", "write_file",
        "filesystem", "fs", "grep", "glob", "str_replace_editor",
        "web_search", "web_fetch",
    ]

    public static func isForbiddenToolName(_ name: String) -> Bool {
        var candidate = name.lowercased()
        if candidate.hasPrefix("gmgn_") { candidate.removeFirst("gmgn_".count) }
        if let range = candidate.range(of: "__", options: .backwards) {
            candidate = String(candidate[range.upperBound...])
        }
        return forbiddenToolNames.contains(candidate)
    }

    /// 正式注册集合 → MCP tools 数组（仅正式 schema；禁止名 fail-closed）。
    public static func toolsJSON(
        registrations: [ResidentDSHHostToolRegistration]
    ) throws -> Data {
        guard !registrations.isEmpty else {
            throw ResidentClaudeMCPBridgeError.invalidRegistrations("本轮没有正式工具")
        }
        var seen = Set<String>()
        var tools: [[String: Any]] = []
        for registration in registrations {
            guard !isForbiddenToolName(registration.declaredName),
                  !isForbiddenToolName(registration.canonicalName) else {
                throw ResidentClaudeMCPBridgeError.forbiddenToolName(registration.canonicalName)
            }
            guard seen.insert(registration.declaredName).inserted else {
                throw ResidentClaudeMCPBridgeError.invalidRegistrations(
                    "工具重复：\(registration.declaredName)"
                )
            }
            guard let object = try? JSONSerialization.jsonObject(with: registration.originalSchemaJSON),
                  let schema = object as? [String: Any] else {
                throw ResidentClaudeMCPBridgeError.invalidRegistrations(
                    "工具 \(registration.canonicalName) 的 schema 不是 JSON 对象"
                )
            }
            tools.append([
                "name": registration.declaredName,
                "description": registration.description,
                "inputSchema": schema,
            ])
        }
        do {
            return try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
        } catch {
            throw ResidentClaudeMCPBridgeError.invalidRegistrations("工具清单无法序列化")
        }
    }

    public static func source(registrations: [ResidentDSHHostToolRegistration]) throws -> String {
        try source(toolsJSON: toolsJSON(registrations: registrations))
    }

    /// 生成 adapter 源码：把边界常量、server 信息与正式工具清单注入受限脚本模板。
    public static func source(toolsJSON: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: toolsJSON),
              let root = object as? [[String: Any]], !root.isEmpty,
              let toolsText = String(data: toolsJSON, encoding: .utf8) else {
            throw ResidentClaudeMCPBridgeError.invalidRegistrations("工具清单为空或不是 JSON 数组")
        }
        // JSON 是 JS 的字面量子集；仅需转义 JS 行分隔符，避免源码被拆行。
        let safeTools = toolsText
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        var text = template
        let stringTokens: [(String, String)] = [
            ("__GRANT_FILENAME__", grantFilename),
            ("__SERVER_NAME__", serverName),
            ("__SERVER_VERSION__", serverVersion),
            ("__PROTOCOL_VERSION__", protocolVersion),
        ]
        for (token, value) in stringTokens {
            text = text.replacingOccurrences(of: token, with: value)
        }
        let numberTokens: [(String, Int)] = [
            ("__MAX_REQUEST_BYTES__", maximumRequestBytes),
            ("__MAX_RESPONSE_BYTES__", maximumResponseBytes),
            ("__MAX_TEXT_BYTES__", maximumTextBytes),
            ("__MAX_IMAGE_BASE64_BYTES__", maximumImageBase64Bytes),
            ("__MAX_HOST_REPLY_BYTES__", maximumHostReplyBytes),
            ("__MAX_GRANT_BYTES__", maximumGrantBytes),
            ("__MAX_CONCURRENT_TOOL_CALLS__", maximumConcurrentToolCalls),
            ("__REQUEST_TIMEOUT_MS__", requestTimeoutMilliseconds),
        ]
        for (token, value) in numberTokens {
            text = text.replacingOccurrences(of: token, with: String(value))
        }
        guard text.contains("__TOOLS_JSON__") else {
            throw ResidentClaudeMCPBridgeError.adapterUnavailable
        }
        text = text.replacingOccurrences(of: "__TOOLS_JSON__", with: safeTools)
        return text
    }

    // MARK: Adapter template (restricted; stdio MCP ↔ reused private HTTP session)

    static let template = #"""
import http from 'node:http'
import fs from 'node:fs'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'

const GRANT_PATH = fileURLToPath(new URL('__GRANT_FILENAME__', import.meta.url))
const SERVER_NAME = '__SERVER_NAME__'
const SERVER_VERSION = '__SERVER_VERSION__'
const PROTOCOL_VERSION = '__PROTOCOL_VERSION__'
const MAX_REQUEST_BYTES = __MAX_REQUEST_BYTES__
const MAX_RESPONSE_BYTES = __MAX_RESPONSE_BYTES__
const MAX_TEXT_BYTES = __MAX_TEXT_BYTES__
const MAX_IMAGE_BASE64_BYTES = __MAX_IMAGE_BASE64_BYTES__
const MAX_HOST_REPLY_BYTES = __MAX_HOST_REPLY_BYTES__
const MAX_GRANT_BYTES = __MAX_GRANT_BYTES__
const MAX_CONCURRENT_TOOL_CALLS = __MAX_CONCURRENT_TOOL_CALLS__
const REQUEST_TIMEOUT_MS = __REQUEST_TIMEOUT_MS__
const TOOLS = __TOOLS_JSON__

const TOOL_NAMES = new Set(
  TOOLS.map(function (tool) { return tool && tool.name })
    .filter(function (name) { return typeof name === 'string' })
)

function byteLength(text) { return Buffer.byteLength(text, 'utf8') }

function boundText(value) {
  const text = typeof value === 'string' ? value : String(value)
  if (byteLength(text) <= MAX_TEXT_BYTES) return text
  const buffer = Buffer.from(text, 'utf8').subarray(0, MAX_TEXT_BYTES)
  return buffer.toString('utf8') + '\n[truncated]'
}

function stringifyValue(value) {
  if (typeof value === 'string') return value
  try {
    const encoded = JSON.stringify(value)
    return typeof encoded === 'string' ? encoded : 'null'
  } catch (_) { return 'null' }
}

function serialize(object) {
  try {
    const line = JSON.stringify(object)
    return typeof line === 'string' ? line : null
  } catch (_) { return null }
}

function writeLine(line) {
  try { process.stdout.write(line + '\n') } catch (_) { /* stdout closed */ }
}

function emit(object, fallbackId) {
  let line = serialize(object)
  if (line === null || byteLength(line) > MAX_RESPONSE_BYTES) {
    line = serialize({
      jsonrpc: '2.0',
      id: fallbackId === undefined ? null : fallbackId,
      error: { code: -32603, message: 'response too large' }
    })
  }
  if (line !== null) writeLine(line)
}

function respondError(id, code, message) {
  emit({ jsonrpc: '2.0', id: id, error: { code: code, message: message } }, id)
}

function respondResult(id, payload) {
  emit({ jsonrpc: '2.0', id: id, result: payload }, id)
}

function safeToolMessage(code) {
  switch (code) {
    case 'grant_revoked': return 'tool session is not authorized'
    case 'tool_session_expired': return 'tool session expired'
    case 'invalid_call_id': return 'invalid tool call'
    case 'tool_not_allowed': return 'unknown tool'
    case 'invalid_arguments': return 'invalid tool arguments'
    case 'schema_unsupported': return 'tool arguments are not supported'
    case 'host_execution_timeout': return 'tool bridge timed out'
    case 'tool_error': return 'tool execution failed'
    default: return 'tool bridge unavailable'
  }
}

function toolErrorResult(message) {
  return { content: [{ type: 'text', text: boundText(message) }], isError: true }
}

function readGrant() {
  let raw
  try {
    // lstat：授权文件必须是宿主写入的普通文件；符号链接/目录一律 fail-closed。
    const stats = fs.lstatSync(GRANT_PATH)
    if (!stats.isFile() || stats.size > MAX_GRANT_BYTES) return null
    raw = fs.readFileSync(GRANT_PATH, 'utf8')
  } catch (_) { return null }
  if (byteLength(raw) > MAX_GRANT_BYTES) return null
  try {
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null
  } catch (_) { return null }
}

// 进程启动时钉住初始 grant 身份（secret + round）：这是本 adapter 进程的不可变
// 授权代。之后每次 tools/call 前与宿主回包前都重读 grant 文件并要求身份仍等于
// 钉住值 —— revoke 后重新 arm 轮换出的新 secret/round 绝不让旧 adapter 进程复活。
const STARTUP_GRANT = readGrant()
const PINNED_SECRET = STARTUP_GRANT && typeof STARTUP_GRANT.secret === 'string' &&
  STARTUP_GRANT.secret.length > 0 ? STARTUP_GRANT.secret : null
const PINNED_ROUND = STARTUP_GRANT && typeof STARTUP_GRANT.round === 'string' &&
  STARTUP_GRANT.round.length > 0 ? STARTUP_GRANT.round : null

// 当前授权裁决：身份钉住 + state=armed + expiresAt 必须存在且为有限数。
// 任何畸形/缺失都 fail-closed 为 unauthorized；仅过期单独区分。
function evaluateGrant() {
  const grant = readGrant()
  if (!grant || grant.state !== 'armed') return { status: 'unauthorized' }
  if (PINNED_SECRET === null || typeof grant.secret !== 'string' || grant.secret !== PINNED_SECRET) {
    return { status: 'unauthorized' }
  }
  if (PINNED_ROUND === null || typeof grant.round !== 'string' || grant.round !== PINNED_ROUND) {
    return { status: 'unauthorized' }
  }
  if (typeof grant.expiresAt !== 'number' || !Number.isFinite(grant.expiresAt)) {
    return { status: 'unauthorized' }
  }
  if (Date.now() >= grant.expiresAt) return { status: 'expired' }
  return { status: 'authorized', grant: grant }
}

function grantAllows(grant, name) {
  const tools = grant && Array.isArray(grant.tools) ? grant.tools : []
  for (const tool of tools) {
    if (tool && tool.name === name) return true
  }
  return false
}

function hostCall(endpoint, secret, name, args) {
  return new Promise(function (resolve) {
    const port = Number(new URL(endpoint.url).port)
    let settled = false
    let buffer = Buffer.alloc(0)
    let request = null
    const deadline = setTimeout(function () { finish(null) }, REQUEST_TIMEOUT_MS)
    function finish(value) {
      if (settled) return
      settled = true
      clearTimeout(deadline)
      try { if (request) request.destroy() } catch (_) { /* ignore */ }
      resolve(value)
    }
    const body = JSON.stringify({ v: 1, callId: 'mcp-' + randomUUID(), name: name, arguments: args })
    request = http.request({
      hostname: '127.0.0.1', port: port, path: '/rpc', method: 'POST', agent: false, maxHeaderSize: 8192,
      headers: {
        'Content-Type': 'application/json', 'Content-Length': byteLength(body),
        'Authorization': 'Bearer ' + secret, 'Connection': 'close'
      }
    }, function (response) {
      // Native http.request never follows redirects; only the private RPC endpoint is used.
      if (response.statusCode !== 200 && response.statusCode !== 403) { finish(null); return }
      if (!/^application\/json(?:\s*;|$)/i.test(String(response.headers['content-type'] || ''))) { finish(null); return }
      response.on('data', function (chunk) {
        if (buffer.length + chunk.length > MAX_HOST_REPLY_BYTES) { finish(null); return }
        buffer = Buffer.concat([buffer, chunk])
      })
      response.on('end', function () {
        let parsed = null
        try { parsed = JSON.parse(buffer.toString('utf8')) } catch (_) { parsed = null }
        finish(parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null)
      })
      response.on('error', function () { finish(null) })
      response.on('aborted', function () { finish(null) })
    })
    request.on('error', function () { finish(null) })
    request.end(body)
  })
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

// JSON-RPC 请求 id 只允许字符串或有限整数；object/array/bool/null/非整数一律拒绝。
function isValidRequestId(value) {
  if (typeof value === 'string') return true
  if (typeof value === 'number') return Number.isInteger(value) && Number.isFinite(value)
  return false
}

async function handleToolsCall(id, params) {
  if (!isPlainObject(params)) { respondError(id, -32602, 'invalid tool call parameters'); return }
  const name = typeof params.name === 'string' ? params.name : null
  if (name === null) { respondError(id, -32602, 'invalid tool call parameters'); return }
  const rawArguments = params.arguments
  let args = {}
  if (rawArguments !== undefined) {
    // arguments 必须是对象；显式 null 也拒绝（缺省才等价空对象）。
    if (!isPlainObject(rawArguments)) {
      respondError(id, -32602, 'invalid tool call parameters')
      return
    }
    args = rawArguments
  }
  if (!TOOL_NAMES.has(name)) { respondResult(id, toolErrorResult('unknown tool')); return }
  const before = evaluateGrant()
  if (before.status === 'expired') { respondResult(id, toolErrorResult('tool session expired')); return }
  if (before.status !== 'authorized') {
    respondResult(id, toolErrorResult('tool session is not authorized'))
    return
  }
  if (!grantAllows(before.grant, name)) { respondResult(id, toolErrorResult('unknown tool')); return }
  const endpoint = before.grant.endpoint
  if (!endpoint || endpoint.version !== 2 || typeof endpoint.url !== 'string' || !/^http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\/rpc$/.test(endpoint.url) || Number(new URL(endpoint.url).port) > 65535 || typeof endpoint.token !== 'string' || endpoint.token.length === 0) { respondResult(id, toolErrorResult('tool bridge unavailable')); return }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(endpoint.token) || endpoint.token !== before.grant.secret) { respondResult(id, toolErrorResult('tool bridge unavailable')); return }
  const reply = await hostCall(endpoint, endpoint.token, name, args)
  // 回包前复核：授权在等待宿主期间被撤销/轮换/过期时，迟到的结果绝不回给模型。
  const after = evaluateGrant()
  if (after.status === 'expired') { respondResult(id, toolErrorResult('tool session expired')); return }
  if (after.status !== 'authorized') {
    respondResult(id, toolErrorResult('tool session is not authorized'))
    return
  }
  if (!grantAllows(after.grant, name)) { respondResult(id, toolErrorResult('unknown tool')); return }
  if (!reply) { respondResult(id, toolErrorResult('tool bridge unavailable')); return }
  if (reply.ok === true) {
    const content = [{ type: 'text', text: boundText(stringifyValue(reply.data === undefined ? null : reply.data)) }]
    const image = reply.image
    if (image && typeof image === 'object' &&
        typeof image.base64 === 'string' && image.base64.length > 0 &&
        image.base64.length <= MAX_IMAGE_BASE64_BYTES) {
      content.push({ type: 'image', data: image.base64, mimeType: 'image/png' })
    }
    respondResult(id, { content: content, isError: false })
    return
  }
  const code = reply.error && typeof reply.error.code === 'string' ? reply.error.code : ''
  if (code === 'tool_error' && reply.data !== undefined) {
    respondResult(id, { content: [{ type: 'text', text: boundText(stringifyValue(reply.data)) }], isError: true })
    return
  }
  respondResult(id, toolErrorResult(safeToolMessage(code)))
}

// stdio tools/call 并发有界：最多 MAX_CONCURRENT_TOOL_CALLS 个在途；超量立即返回
// 固定 busy 工具错误，绝不建立无界 Promise / 连接 / 排队。
let inFlightToolCalls = 0

async function dispatchToolsCall(id, params) {
  if (inFlightToolCalls >= MAX_CONCURRENT_TOOL_CALLS) {
    respondResult(id, toolErrorResult('tool bridge busy'))
    return
  }
  inFlightToolCalls += 1
  try {
    await handleToolsCall(id, params)
  } catch (_) {
    respondResult(id, toolErrorResult('tool bridge unavailable'))
  } finally {
    inFlightToolCalls -= 1
  }
}

function handleLine(line) {
  if (line.trim().length === 0) return
  let message = null
  try { message = JSON.parse(line) } catch (_) { respondError(null, -32700, 'parse error'); return }
  if (!isPlainObject(message)) { respondError(null, -32600, 'invalid request'); return }
  if (message.jsonrpc !== '2.0') { respondError(null, -32600, 'invalid request'); return }
  const method = typeof message.method === 'string' ? message.method : null
  const hasId = Object.prototype.hasOwnProperty.call(message, 'id')
  const id = hasId ? message.id : null
  if (method === null) { if (hasId) respondError(null, -32600, 'invalid request'); return }
  if (hasId && !isValidRequestId(id)) { respondError(null, -32600, 'invalid request'); return }
  // params 若出现必须是对象（数组/字符串/null/标量都拒绝）。
  if (Object.prototype.hasOwnProperty.call(message, 'params') && !isPlainObject(message.params)) {
    if (hasId) respondError(id, -32602, 'invalid params')
    return
  }
  if (!hasId) return
  switch (method) {
    case 'initialize':
      respondResult(id, {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION }
      })
      return
    case 'ping':
      respondResult(id, {})
      return
    case 'tools/list':
      respondResult(id, { tools: TOOLS })
      return
    case 'tools/call':
      dispatchToolsCall(id, message.params)
      return
    default:
      respondError(id, -32601, 'method not found')
      return
  }
}

let pending = Buffer.alloc(0)
let discarding = false
process.stdin.on('data', function (chunk) {
  let offset = 0
  while (offset < chunk.length) {
    const newline = chunk.indexOf(10, offset)
    if (discarding) {
      if (newline < 0) return
      discarding = false
      offset = newline + 1
      continue
    }
    if (newline < 0) {
      const piece = chunk.subarray(offset)
      if (pending.length + piece.length > MAX_REQUEST_BYTES) {
        pending = Buffer.alloc(0)
        discarding = true
        respondError(null, -32700, 'request too large')
        return
      }
      pending = Buffer.concat([pending, piece])
      return
    }
    const piece = chunk.subarray(offset, newline)
    if (pending.length + piece.length > MAX_REQUEST_BYTES) {
      pending = Buffer.alloc(0)
      respondError(null, -32700, 'request too large')
    } else {
      const line = Buffer.concat([pending, piece]).toString('utf8')
      pending = Buffer.alloc(0)
      handleLine(line)
    }
    offset = newline + 1
  }
})
process.stdin.on('end', function () { process.exit(0) })
process.stdin.on('error', function () { process.exit(0) })
"""#
}

// MARK: - Host session (reuses ResidentDSHHostToolsChannel)

/// 一次 Claude Code 工具轮次的宿主会话：复用既有 `ResidentDSHHostToolsChannel`
/// （会话级 HTTP + 每轮 secret + 授权代），并在同一私有目录准备受限 adapter、
/// 授权文件与 `--mcp-config`。
///
/// 生产接线（`AgentConversationService.sendViaClaude`，已完成）：
/// ```
/// // 每轮 fresh：新 spawn 一个 adapter 进程，绝不复用旧 adapter across arm。
/// let session = try ResidentClaudeMCPHostSession.start(
///     configuration: .init(scope: scope, worldID: worldTools.worldID,
///                          registrations: ResidentDSHHostToolSet.parse(schemasJSON:),
///                          handler: { request in
///                              // 执行当前性仍由原 worldTools 与通道 gate 决定。
///                              let reply = await worldTools.call(
///                                  request.callID, request.canonicalName, request.argumentsJSON)
///                              return ResidentDSHHostToolReply(
///                                  resultJSON: reply.resultJSON, isError: reply.isError,
///                                  imagePNGData: reply.image?.pngData)
///                          },
///                          nodeExecutable: nodePath),
///     deadline: Date().addingTimeInterval(turnTimeout))
/// // 参数：claudeArguments(mcpConfigPath: session.configFileURL.path,
/// //                      allowedToolNames: session.allowedToolNames)
/// // 纯聊天：不建 session，仅写空 mcpServers 的 0600 私有 config。
/// // 取消/下一轮/换 scope：withTaskCancellationHandler 里先 session.revoke()，
/// // 无论成败 finally session.stop()（清 adapter/config/grant 与通道目录）。
/// // 进程环境：ResidentClaudeEnvironment 白名单 + 自建 CLAUDE_CONFIG_DIR + 私有 cwd；
/// // 绝不修改 HOME，绝不读取/复制用户凭据或 Claude 配置。
/// ```
/// 本 bridge 只提供受限 adapter、私有 `--mcp-config` 与逐项放行名，不启动 CLI、
/// 不持有 Service 状态。
public final class ResidentClaudeMCPHostSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let scope: String
        public let worldID: String
        public let registrations: [ResidentDSHHostToolRegistration]
        public let handler: @MainActor @Sendable (ResidentDSHHostToolRequest) async -> ResidentDSHHostToolReply
        public let nodeExecutable: URL

        public init(
            scope: String,
            worldID: String,
            registrations: [ResidentDSHHostToolRegistration],
            handler: @escaping @MainActor @Sendable (ResidentDSHHostToolRequest) async -> ResidentDSHHostToolReply,
            nodeExecutable: URL
        ) {
            self.scope = scope
            self.worldID = worldID
            self.registrations = registrations
            self.handler = handler
            self.nodeExecutable = nodeExecutable
        }
    }

    private let lock = NSLock()
    private let configuration: Configuration
    private let channel: ResidentDSHHostToolsChannel
    private let deadlineBox: ResidentClaudeMCPDeadlineBox
    private var stopped = false

    public let directoryURL: URL
    public let adapterFileURL: URL
    public let grantFileURL: URL
    public let configFileURL: URL
    public var rpcURL: String { channel.rpcURL }

    /// 本会话 `--allowedTools` 的逐项精确放行名（每轮正式工具一条）。
    public var allowedToolNames: [String] {
        ResidentClaudeMCPAdapter.allowedToolNames(registrations: configuration.registrations)
    }

    /// 启动宿主通道 + 写 adapter/config + 首次 arm。任何中途失败都回收通道、半成品
    /// 与本次自建的私有目录（配置启动的通道不整目录自删，见下）。
    public static func start(
        configuration: Configuration,
        deadline: Date
    ) throws -> ResidentClaudeMCPHostSession {
        let toolsJSON = try ResidentClaudeMCPAdapter.toolsJSON(
            registrations: configuration.registrations
        )
        let source = try ResidentClaudeMCPAdapter.source(toolsJSON: toolsJSON)
        let deadlineBox = ResidentClaudeMCPDeadlineBox(deadline)
        let channel = try ResidentDSHHostToolsChannel.start(
            configuration: ResidentDSHHostToolsChannel.Configuration(
                scope: configuration.scope,
                worldID: configuration.worldID,
                registrations: configuration.registrations,
                handler: { request in
                    // 执行前过期复核：过期后即使授权文件仍被读到也零副作用。
                    guard Date() < deadlineBox.current else {
                        return ResidentClaudeMCPHostSession.expiredReply
                    }
                    return await configuration.handler(request)
                }
            )
        )
        do {
            let session = ResidentClaudeMCPHostSession(
                configuration: configuration,
                channel: channel,
                deadlineBox: deadlineBox
            )
            try session.prepare(source: source)
            try session.arm(worldRevision: nil, deadline: deadline)
            return session
        } catch {
            // 配置启动的通道不整目录自删（removesDirectoryOnStop == false）：stop() 只
            // 回收 grant/listener。start 抛错时调用方拿不到 session，无法走其 defer 的整目录
            // 回收，因此这里必须显式删除本次自建私有目录，避免 prepare/arm 失败泄漏。
            channel.stop()
            try? FileManager.default.removeItem(at: channel.directoryURL)
            throw error
        }
    }

    private init(
        configuration: Configuration,
        channel: ResidentDSHHostToolsChannel,
        deadlineBox: ResidentClaudeMCPDeadlineBox
    ) {
        self.configuration = configuration
        self.channel = channel
        self.deadlineBox = deadlineBox
        self.directoryURL = channel.directoryURL
        self.adapterFileURL = channel.directoryURL
            .appendingPathComponent(ResidentClaudeMCPAdapter.filename)
        self.grantFileURL = channel.directoryURL
            .appendingPathComponent(ResidentClaudeMCPAdapter.grantFilename)
        self.configFileURL = channel.directoryURL
            .appendingPathComponent(ResidentClaudeMCPAdapter.configFilename)
    }

    // MARK: Lifecycle

    private func prepare(source: String) throws {
        let manager = FileManager.default
        do {
            try Data(source.utf8).write(to: adapterFileURL, options: [.atomic])
            try manager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: adapterFileURL.path
            )
            let config = try mcpConfigJSON()
            try config.write(to: configFileURL, options: [.atomic])
            try manager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: configFileURL.path
            )
        } catch {
            throw ResidentClaudeMCPBridgeError.adapterUnavailable
        }
    }

    /// 本轮授权生效：推进通道授权代/轮换 secret，并重写 adapter 侧的 0600 授权文件
    /// （state=armed、expiresAt、HTTP endpoint、secret、round、本轮工具名单）。
    ///
    /// 注意：adapter 进程在**启动时**钉住其 grant 身份（secret + round），因此 re-arm
    /// 之后必须重新 spawn 新的 adapter 进程；旧进程即使重读到新 secret 也不会复活。
    public func arm(worldRevision: UInt64?, deadline: Date) throws {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { throw ResidentClaudeMCPBridgeError.sessionStopped }
        deadlineBox.set(deadline)
        try channel.arm(worldRevision: worldRevision)
        guard let channelGrant = Self.readGrant(at: channel.grantFileURL),
              let secret = channelGrant["secret"] as? String, !secret.isEmpty,
              let round = channelGrant["round"] as? String, !round.isEmpty else {
            channel.revoke()
            throw ResidentClaudeMCPBridgeError.grantWriteFailed
        }
        try writeGrant(secret: secret, round: round, deadline: deadline)
    }

    /// 撤销本轮授权：删除 adapter 授权文件并让通道关闸（secret 轮换 + epoch 推进）。
    /// 迟到的工具调用（含已读到旧 secret 的请求）一律被拒绝。
    public func revoke() {
        try? FileManager.default.removeItem(at: grantFileURL)
        channel.revoke()
    }

    /// 会话销毁：撤销授权、清理本次会话文件并停止复用通道（幂等）。
    public func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        try? FileManager.default.removeItem(at: grantFileURL)
        try? FileManager.default.removeItem(at: configFileURL)
        try? FileManager.default.removeItem(at: adapterFileURL)
        channel.stop()
    }

    public var isExpired: Bool { Date() >= deadlineBox.current }

    // MARK: MCP config / Claude wiring

    /// `--mcp-config` 的 JSON：只挂载本受限 adapter，command 为真实 node 可执行文件。
    public func mcpConfigJSON() throws -> Data {
        let payload: [String: Any] = [
            "mcpServers": [
                ResidentClaudeMCPAdapter.serverName: [
                    "type": "stdio",
                    "command": configuration.nodeExecutable.path,
                    "args": [adapterFileURL.path],
                ],
            ],
        ]
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw ResidentClaudeMCPBridgeError.adapterUnavailable
        }
    }

    /// 追加到 Claude Code 参数后的接线片段：`--mcp-config <private config>`。
    public var mcpConfigArguments: [String] {
        ["--mcp-config", configFileURL.path]
    }

    // MARK: Grant writing / reading (lock-free; files are atomic + 0600)

    private func writeGrant(secret: String, round: String, deadline: Date) throws {
        var tools: [[String: Any]] = []
        for registration in configuration.registrations {
            tools.append([
                "name": registration.declaredName,
                "canonical": registration.canonicalName,
            ])
        }
        let payload: [String: Any] = [
            "protocol": 1,
            "state": "armed",
            "expiresAt": NSNumber(value: Int64((deadline.timeIntervalSince1970 * 1000).rounded())),
            "endpoint": channel.endpoint(token: secret),
            "secret": secret,
            "round": round,
            "scope": configuration.scope,
            "worldID": configuration.worldID,
            "tools": tools,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw ResidentClaudeMCPBridgeError.grantWriteFailed
        }
        do {
            try data.write(to: grantFileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: grantFileURL.path
            )
            guard try Data(contentsOf: grantFileURL) == data else {
                throw ResidentClaudeMCPBridgeError.grantWriteFailed
            }
        } catch let error as ResidentClaudeMCPBridgeError {
            throw error
        } catch {
            throw ResidentClaudeMCPBridgeError.grantWriteFailed
        }
    }

    private static func readGrant(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    static let expiredReply = ResidentDSHHostToolReply(
        resultJSON: (try? JSONSerialization.data(withJSONObject: [
            "ok": false,
            "error": ["code": "tool_session_expired", "message": "本轮工具授权已过期"],
        ], options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8),
        isError: true
    )
}

// MARK: - Deadline box

/// 可在轮次间推进的过期时刻容器（通道 handler 在 @MainActor 上读，arm 在任意线程写）。
private final class ResidentClaudeMCPDeadlineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func set(_ newValue: Date) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    var current: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
