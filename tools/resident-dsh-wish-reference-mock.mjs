// Loopback-only provider. Each next typed call is derived from the previous host result.
import { createServer } from 'node:http'
import { appendFileSync } from 'node:fs'

const names = ['search_wish_reference_images', 'register_wish_reference_image', 'submit_wish_generation']
function reply(res, delta, finish) {
  res.writeHead(200, { 'content-type': 'text/event-stream' })
  res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta, finish_reason: null }] })}\n\n`)
  res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: finish }] })}\n\n`)
  res.end('data: [DONE]\n\n')
}
const server = createServer(async (req, res) => {
  if (req.method !== 'POST' || !req.url.endsWith('/chat/completions')) return res.writeHead(404).end()
  if (req.headers.authorization !== 'Bearer mock-key') return res.writeHead(401).end()
  const chunks = []; for await (const chunk of req) chunks.push(chunk)
  const body = JSON.parse(Buffer.concat(chunks).toString())
  appendFileSync(process.env.REQUESTS_FILE, JSON.stringify({ body }) + '\n')
  const offered = (body.tools || []).map(t => t.function?.name)
  if (!offered.some(n => n?.startsWith('gmgn_'))) return reply(res, { content: 'Test title' }, 'stop')
  const missing = names.filter(n => !offered.includes('gmgn_' + n))
  if (missing.length) return reply(res, { content: 'MISSING_TOOLS:' + missing.join(',') }, 'stop')
  const messages = body.messages || []
  const lastUser = messages.findLastIndex(m => m.role === 'user')
  const results = messages.slice(lastUser + 1).filter(m => m.role === 'tool')
  const resultText = m => typeof m.content === 'string' ? m.content : (m.content || []).map(b => b.text || '').join('')
  const previous = results.length ? resultText(results.at(-1)) : ''
  let args
  if (!results.length) args = { query: 'red wooden chair' }
  else if (results.length === 1) {
    const image = previous.match(/https:\/\/reference\.invalid\/[^"\s\\]+/)
    if (!image) return reply(res, { content: 'BROKEN_SEARCH_RESULT:' + previous }, 'stop')
    args = { image_url: image[0], display_name: 'red wooden chair' }
  } else if (results.length === 2) {
    const attachment = previous.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)
    if (!attachment) return reply(res, { content: 'BROKEN_REGISTER_RESULT:' + previous }, 'stop')
    args = { attachment_id: attachment[0], name: 'red chair', height_meters: 0.8 }
  } else {
    return reply(res, { content: previous.includes('wish-offline-accepted') ? 'WISH_REFERENCE_CHAIN_FINAL_OK' : 'BROKEN_SUBMIT_RESULT' }, 'stop')
  }
  reply(res, { tool_calls: [{ index: 0, id: `wish-call-${results.length}`, type: 'function', function: { name: 'gmgn_' + names[results.length], arguments: JSON.stringify(args) } }] }, 'tool_calls')
})
server.listen(0, '127.0.0.1', () => console.log(`READY http://127.0.0.1:${server.address().port}`))
process.on('SIGTERM', () => { server.close(); server.closeAllConnections() })
