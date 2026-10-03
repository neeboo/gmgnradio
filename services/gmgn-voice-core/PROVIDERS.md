# 独立语音供应商

当前产品交互是按住说话、松开提交、回答正常播放。流式描述音频与转写传输方式，不代表持续通话；这里不引入 LiveKit、ElevenAgents 或供应商对话 Agent。

| 供应商 | TTS | ASR | 当前 Rust 实现范围 |
| --- | --- | --- | --- |
| ElevenLabs | HTTP `/v1/text-to-speech/{voice_id}/stream` | Scribe WebSocket，可选择 manual commit | HTTP 流式 PCM 输出；ASR typed 输入、commit 和转写事件协议，尚未实现 ASR socket transport |
| Fish Audio | HTTP `/v1/tts` 流式响应 | 官方 `/v1/asr` 是单文件上传接口 | HTTP 流式 PCM 输出；不将文件 ASR 宣称为流式，不虚构 ASR WebSocket |

两个 HTTP TTS 请求都输出 24 kHz、单声道 PCM16 little-endian。响应 chunk 立即交给有界队列，不等待整段下载；每个输出包不超过 16 KiB，队列最多 8 包，总响应限制 32 MiB。HTTP 包边界可能切开 PCM sample，宿主必须衔接尾字节。生产请求只使用固定 HTTPS 供应商域名，禁止跟随重定向，避免 API key 向重定向目标泄露。配置类型不实现 Debug 或 Serialize；错误只保留 HTTP 状态或本地错误类别，不返回供应商响应正文。

每条输出带独立 generation。宿主必须在播放队列再次核对 generation；取消会终止网络任务、丢弃未消费输出，不能撤销宿主已经取得的音频。供应商 HTTP timeout 为 120 秒，网络连接 timeout 为 15 秒。没有透明重连或跨供应商静默兜底。

ElevenLabs ASR 输入是已重采样的 16 kHz mono PCM16，每包最多 32 KiB。输入包 `commit=false`，松开说话时单独发送空音频 `commit=true`。`partial_transcript` 只用于 UI 展示，只有 `committed_transcript` 才能用于提交用户消息；连接生命周期与 generation 隔离由未来 transport/宿主负责。

Fish ASR 官方接受 WAV 等音频文件，不接受裸 PCM 或 JSON base64。官方文档目前没有公开流式 ASR 端点，因此需要流式 ASR 的配置应选择支持该能力的供应商，并明确告知用户；文件转写能力可另行实现，不能把它标记成流式。

## 验证范围

`cargo test -p gmgn-voice-core providers::` 覆盖首包在 HTTP 响应结束前到达、取消后不再交付、302 不重试/跟随，以及按住说话手动 commit 的协议。不读取凭据、不调用付费供应商、不启动 App。尚未完成 App 接入、真实供应商首音频延迟和真实声音输出验收。

## 官方接口依据（2026-10-04 核对）

- [ElevenLabs HTTP 流式 TTS](https://elevenlabs.io/docs/api-reference/text-to-speech/stream)
- [ElevenLabs Scribe WebSocket](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)
- [ElevenLabs 手动提交策略](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies)
- [Fish Audio TTS](https://docs.fish.audio/api-reference/endpoint/openapi-v1/text-to-speech)
- [Fish Audio 单文件 ASR](https://docs.fish.audio/api-reference/endpoint/openapi-v1/speech-to-text)
