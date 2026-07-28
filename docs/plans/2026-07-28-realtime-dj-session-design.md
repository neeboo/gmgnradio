# gmgn radio 实时 DJ 会话抽象设计

日期：2026-07-28  
状态：已确认，进入实施

## 目标

gmgn radio 复用已经接通过的两条实时语音路径：

- 阿里云百炼 `Qwen3.5-Omni-Realtime`：当前实现通过 DashScope WebSocket 发送音频、更新上下文并接收语音、字幕、VAD 与工具事件。
- 豆包端到端实时语音：当前实现通过 ByteRTC 房间承载音频，通过 `StartVoiceChat`、`UpdateVoiceChat` 和 `StopVoiceChat` 管理模型会话、打断与工具结果。
- ElevenLabs Agents：使用官方 Swift SDK 通过 WebRTC 连接，复用其 VAD、打断、字幕、上下文更新、音色覆盖和客户端工具调用。

macOS 播放器只依赖统一的实时 DJ 会话合同。供应商 SDK、鉴权、事件名、采样率和房间生命周期留在各自适配器中。

## 边界

抽象位于“完整实时会话”层，不重写供应商已经提供的 VAD、回声消除、轮次判断、打断和重连。

```text
RadioAudioGraph
├── Music bus
├── DJ bus
└── Microphone
       │
RealtimeDJSession
├── BailianRealtimeSession
├── DoubaoRTCSession
└── ElevenLabsRealtimeSession
```

`RadioAudioGraph` 负责音乐、混音、压低和设备切换。`RealtimeDJSession` 负责实时语音生命周期。DJ 节目计划通过结构化上下文更新进入会话，播放器工具通过统一工具调用返回。

## 共同合同

会话必须支持：

- 使用服务端签发的不透明短期票据连接；
- 分开控制麦克风采集和音频上传；
- 更新当前歌曲、下一首歌、节目摘要和用户即时指令；
- 主动打断 DJ；
- 返回工具执行结果；
- 关闭并释放会话；
- 以统一事件报告连接、用户说话、DJ 说话、字幕、工具调用和故障。

供应商差异通过能力集合表达，不用最低能力限制全部实现。

## 供应商映射

### 百炼

- `session.update` 对应上下文更新；
- `input_audio_buffer.speech_started/stopped` 对应用户语音边界；
- `conversation.item.input_audio_transcription.*` 对应用户字幕；
- `response.created/done` 对应 DJ 回合；
- `response.audio.*` 对应 DJ 音频；
- `response.function_call_arguments.done` 对应工具调用；
- `response.cancel` 或当前模型支持的取消事件对应打断。

### 豆包

- ByteRTC 创建引擎、加入房间、采集与发布对应媒体生命周期；
- `StartVoiceChat` 对应开始模型任务；
- `UpdateVoiceChat Command=interrupt` 对应打断；
- `UpdateVoiceChat Command=function` 对应工具结果；
- RTC 字幕回调对应用户和 DJ 最终字幕；
- 房间连接、首帧、音量与 VAD 回调归一化为共同事件。

### ElevenLabs

- 服务端签发的短期 conversation token 放入不透明会话票据；
- `ConversationConfig` 的音色覆盖对应用户选择的 DJ 音色；
- `updateContext` 对应节目计划和当前播放上下文更新；
- `interruptAgent` 对应主动打断；
- `onUnhandledClientToolCall` 与 `sendToolResult` 对应本地工具循环；
- Agent 状态、用户/DJ 字幕、断线和错误回调归一化为共同事件；
- 官方 SDK 内部使用 LiveKit WebRTC，该实现细节留在 ElevenLabs 适配器中。

## 生命周期规则

1. 采集麦克风不代表上传，两个状态必须独立。
2. 每次连接和供应商切换增加 `generation`。
3. 旧 `generation` 的迟到事件全部丢弃。
4. 切换供应商只替换实时会话，音乐继续播放。
5. 工具调用使用稳定调用 ID，重复投递只能执行一次。
6. 供应商错误不得暴露密钥、原始音频或完整私人对话。

## 第一阶段范围

本阶段实现 Swift 合同、三家供应商的事件归一化、会话协调器与 ElevenLabs 官方 Swift SDK 适配器。真实凭证由服务端签发短期票据；百炼和豆包的网络适配继续按各自供应商任务推进。ElevenLabs 远端音轨接入自有 `AVAudioEngine` 仍需专项验收。
