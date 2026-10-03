# gmgn-voice-core

第一阶段跨平台语音协议核心，目前尚未接入 App。范围为按住说话转写与独立流式 TTS，不包含实时双向通话、抢话、VAD 通话编排或 LiveKit。

## 百炼流式 TTS

迁移默认使用 `tts_stream::TtsStream`。真实 `qwen3-tts-flash-realtime` WebSocket 连接在 `session.updated` 后可持续 `append_text`，`finish_input` 通知文本结束。每个 `response.audio.delta` 独立解码后立即从 `next_event` 输出 PCM16 little-endian 单声道 24 kHz，不等待整句 `response.done`。最终 `session.finished` 才输出合成流结束；这不等于硬件播放完毕或语音交付确认。

输出为 8 格有界队列、每条 WS 消息最多 256 KiB；消费者慢时停止读下一消息，形成背压。每个连接独立 generation UUID，`cancel` 清空已排队音频并终止任务，Drop 同样终止任务；不自动重连旧朗读。消费者还需按 generation 屏蔽已交给设备的旧音频。

协议依据：[连接](https://help.aliyun.com/en/model-studio/interactive-process-of-qwen-tts-realtime-synthesis)、[客户端事件](https://help.aliyun.com/en/model-studio/qwen-tts-realtime-client-events)、[服务端事件](https://help.aliyun.com/en/model-studio/qwen-tts-realtime-server-events)。本地 WS 测试覆盖首块在 done 前交付、背压、取消、错误脱敏与 response ID 隔离；不替代真实服务或 App 验收。

## 旧 HTTP 协议参考

`text_chunks`、`BailianTts::synthesize_chunk` 保留旧 Swift `qwen3-tts-flash` 请求和安全下载行为，供协议比较；整段下载接口不能作为此次迁移的默认播放实现。

下载仅接受无用户信息、无显式端口的 `.aliyuncs.com` URL；HTTP 签名地址升级 HTTPS，保留 query；不跟随重定向、不向音频地址发送 API key。JSON 和音频分别限制 1 MiB、16 MiB，并在流式读取中检查限制。错误不携带原始响应、凭据或签名 URL。

系统权限、录音、播放、人物嘴型及场景渲染继续由现有平台层承担。`asr_stream::AsrStream` 提供百炼与 ElevenLabs Scribe 的真实 WebSocket 传输：按住时分块上传 PCM16LE 单声道 16 kHz，松开调用 `commit`，接收 partial/final；一个连接对应一个按住说话 turn，final 后关闭，不重连旧语音。输入与输出队列各 8 格，每块输入至多 32768 字节；取消清空旧转写并终止 socket task。App 接入和真实端到端验收待完成。ElevenLabs 与 Fish Audio 独立流式 TTS 由对应 provider 实现，当前不依赖完整会话 SDK 或 LiveKit。

ASR 协议依据：[百炼 manual commit](https://help.aliyun.com/en/model-studio/qwen-asr-realtime-client-events)、[ElevenLabs WebSocket](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)、[Scribe 事件](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference)。百炼 manual 模式的实时转写结果可能在松开 commit 后才产生；提前上传仍是流式音频传输，不保证按住期间产生文字。

验证：`cargo test -p gmgn-voice-core`。本地 HTTP 测试验证流式长度限制、HTTP 错误脱敏、禁止重定向以及下载请求无默认凭据；不需要真实服务密钥。
