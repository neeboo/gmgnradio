// 离线组装验证用的本地 DeepSeek 兼容 mock provider（真实安装 DSH 自带的
// @deepseek-ai/dsh-llm-mock-server 库驱动；仅监听 loopback，绝不触达真实模型）。
// 行为：第一个到达的请求回复 `tool_call_success`（--tool-name/--tool-arguments），
// 之后所有请求回复 success（--success-text），并允许中间混入 session-title 等
// 次要请求。收到 SIGTERM 时把每个请求的解析后 body 追加写进 REQUESTS_FILE。
import { startMockLlmServer } from 'file:///Users/ghostcorn/dev/deepseek-harness/apps/cli/node_modules/@deepseek-ai/dsh-llm-mock-server/lib/index.js'
import { appendFileSync } from 'node:fs'

const requestsFile = process.env.REQUESTS_FILE || ''
const sequence = (process.env.SEQUENCE || 'tool_call_success,success').split(',').filter(Boolean)
const repeatLast = (process.env.REPEAT_LAST || '1') === '1'
const toolName = process.env.TOOL_NAME || 'gmgn_read_wish_generation'
const toolArguments = process.env.TOOL_ARGUMENTS || '{}'
const successText = process.env.SUCCESS_TEXT || 'GMGN_NATIVE_ASSEMBLY_FINAL_OK'

const server = await startMockLlmServer({
  host: '127.0.0.1',
  port: 0,
  apiKey: process.env.MOCK_API_KEY || 'mock-key',
  sequence,
  repeatLast,
  toolName,
  toolArguments,
  successText,
  chunkSize: 128,
  chunkDelayMs: 2,
})

console.log('READY ' + server.baseURL)

// 增量落盘：每个请求结束后立即追加，供组装 harness 在 dsh 退出后读取。
let flushed = 0
function flushRequests() {
  if (!requestsFile) return
  const records = server.requests
  while (flushed < records.length) {
    const record = records[flushed]
    flushed += 1
    appendFileSync(
      requestsFile,
      JSON.stringify({
        attempt: record.attempt,
        scriptBehavior: record.scriptBehavior,
        behavior: record.behavior,
        path: record.path,
        body: record.body,
      }) + '\n',
    )
  }
}
const flushTimer = setInterval(flushRequests, 150)

const done = new Promise((resolve) => {
  process.on('SIGTERM', async () => {
    clearInterval(flushTimer)
    try {
      flushRequests()
    } finally {
      await server.close()
      resolve()
    }
  })
})
await done
