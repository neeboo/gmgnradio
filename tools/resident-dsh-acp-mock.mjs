// 离线 ACP 组装验证用的「按请求内容决定行为」的本地 OpenAI 兼容 mock provider
// （真实安装 DSH 的 ACP runtime 驱动；只监听 127.0.0.1，绝不触达真实模型/凭据）。
//
// 与 resident-dsh-mock-llm.mjs（按固定序列消费）不同，本驱动按**请求内容**决定
// 回复，从而在真实 ACP 持久会话跨多轮时保持确定性（DSH 会在各轮之间穿插
// session-title 等不携带工具的小请求，固定序列会被这些请求偏移）：
//   - 请求消息里已有 role=tool（本运行已执行过宿主工具）→ 直接给最终文本
//     （工具结果已回到同一 agent 运行，模型据此给出 final）；
//   - 请求携带 gmgn_* 工具且本轮尚无工具结果 → 依据 CONTROL_FILE（tool | final |
//     stall）回复：tool = 原生 tool_call（DSH 会执行插件→宿主），final = 直接最终
//     文本，stall = 打开 SSE 后不再写（供取消窗口使用，直到客户端中止）；
//   - 其余请求（title 等无工具请求）→ 最终文本。
// SIGTERM 时把每个请求的解析后 body 追加写进 REQUESTS_FILE。
import { createServer } from 'node:http'
import { appendFileSync, readFileSync } from 'node:fs'

const host = '127.0.0.1'
const port = Number(process.env.MOCK_PORT || 0)
const apiKey = process.env.MOCK_API_KEY || 'mock-key'
const successText = process.env.SUCCESS_TEXT || 'GMGN_ACP_NATIVE_ASSEMBLY_FINAL_OK'
const toolName = process.env.TOOL_NAME || 'gmgn_read_wish_generation'
const toolArguments = process.env.TOOL_ARGUMENTS || '{}'
const controlFile = process.env.CONTROL_FILE || ''
const requestsFile = process.env.REQUESTS_FILE || ''

function currentControl() {
  if (!controlFile) return 'tool'
  try {
    const text = readFileSync(controlFile, 'utf8').trim()
    if (text === 'final' || text === 'stall' || text === 'tool') return text
  } catch (_) {}
  return 'tool'
}

function writeAll(response, payload) {
  response.write(`data: ${typeof payload === 'string' ? payload : JSON.stringify(payload)}\n\n`)
}

function openSse(response) {
  response.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache',
    'connection': 'keep-alive',
  })
  response.flushHeaders()
}

function sendToolCall(response, name, argumentsJSON) {
  const midpoint = Math.max(1, Math.floor(argumentsJSON.length / 2))
  openSse(response)
  writeAll(response, { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: 'mock-call-1', type: 'function', function: { name, arguments: argumentsJSON.slice(0, midpoint) } }] }, finish_reason: null }] })
  writeAll(response, { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: argumentsJSON.slice(midpoint) } }] }, finish_reason: null }] })
  writeAll(response, { choices: [{ index: 0, delta: { content: '' }, finish_reason: 'tool_calls' }], usage: { prompt_tokens: 3, completion_tokens: 2 } })
  writeAll(response, '[DONE]')
  response.end()
}

function sendFinal(response) {
  openSse(response)
  writeAll(response, { choices: [{ index: 0, delta: { role: 'assistant', content: '' }, finish_reason: null }] })
  writeAll(response, { choices: [{ index: 0, delta: { content: successText }, finish_reason: null }] })
  writeAll(response, { choices: [{ index: 0, delta: { content: '' }, finish_reason: 'stop' }], usage: { prompt_tokens: 3, completion_tokens: Array.from(successText).length } })
  writeAll(response, '[DONE]')
  response.end()
}

function stall(response) {
  openSse(response)
  // 保持连接打开且不写任何数据：给宿主一个确定的取消窗口；客户端中止时连接关闭。
}

function lastUserIndex(messages) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index] && messages[index].role === 'user') return index
  }
  return -1
}

// 只在「最近一个 user 轮之后」出现过 role=tool 才算本轮工具已完成 —— 持久会话会
// 把更早轮的工具结果留在历史里，不能因此把新一轮误判为续写。
function sawToolResultInCurrentTurn(messages) {
  const lastUser = lastUserIndex(messages)
  for (let index = lastUser + 1; index < messages.length; index += 1) {
    if (messages[index] && messages[index].role === 'tool') return true
  }
  return false
}

function hasGmgnTool(tools) {
  return Array.isArray(tools) && tools.some((t) => {
    const fn = t && (t.function || t)
    const name = fn && fn.name
    return typeof name === 'string' && name.startsWith('gmgn_')
  })
}

let requestIndex = 0
function record(body) {
  requestIndex += 1
  if (!requestsFile) return
  appendFileSync(requestsFile, JSON.stringify({
    attempt: requestIndex,
    control: currentControl(),
    path: '/v1/chat/completions',
    body,
  }) + '\n')
}

const server = createServer((request, response) => {
  if (request.method !== 'POST' || !request.url.endsWith('/chat/completions')) {
    response.writeHead(404).end()
    return
  }
  if (request.headers.authorization !== `Bearer ${apiKey}`) {
    response.writeHead(401, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ error: { message: 'invalid mock bearer token', code: 'invalid_api_key' } }))
    return
  }
  const chunks = []
  request.on('data', (chunk) => chunks.push(Buffer.from(chunk)))
  request.on('end', () => {
    let body = {}
    try {
      body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    } catch (_) {
      response.writeHead(400).end(JSON.stringify({ error: { message: 'bad json' } }))
      return
    }
    record(body)
    const messages = body.messages || []
    const tools = body.tools || []
    if (sawToolResultInCurrentTurn(messages)) { sendFinal(response); return }
    if (hasGmgnTool(tools)) {
      const control = currentControl()
      if (control === 'stall') { stall(response); return }
      if (control === 'tool') { sendToolCall(response, toolName, toolArguments); return }
    }
    sendFinal(response)
  })
})

const serverHandle = await new Promise((resolve) => {
  const handle = server.listen(port, host, () => resolve(handle))
})
const address = serverHandle.address()
console.log('READY http://' + (typeof address === 'object' ? address.address + ':' + address.port : address))

const done = new Promise((resolve) => {
  process.on('SIGTERM', () => { server.close(() => resolve()); server.closeAllConnections?.() })
})
await done
