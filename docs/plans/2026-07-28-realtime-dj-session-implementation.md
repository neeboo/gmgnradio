# Realtime DJ Session Abstraction Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 gmgn radio macOS 客户端建立基于既有百炼与豆包实现的供应商无关实时 DJ 会话合同。

**Architecture:** Swift 客户端以 `RealtimeDJSession` 表达完整实时语音会话，并用 `RealtimeDJSessionController` 管理激活、切换和过期事件隔离。百炼和豆包各自维护事件映射器，后续真实 SDK 只需实现同一合同。

**Tech Stack:** Swift 6、Swift Concurrency、Swift Testing、XcodeGen、现有 gmgn radio macOS 工程。

---

### Task 1: 定义实时 DJ 会话合同

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/RealtimeDJSession.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/VoiceSession/RealtimeDJSessionTests.swift`

**Step 1: 写失败测试**

测试百炼与豆包能力集合、票据不暴露供应商凭证结构，以及采集和上传状态彼此独立。

**Step 2: 运行定向测试并确认失败**

Run:

```bash
cd apps/macos
xcodegen generate
xcodebuild test -project GMGNRadio.xcodeproj -scheme GMGNRadio \
  -destination 'platform=macOS' \
  -only-testing:GMGNRadioTests/RealtimeDJSessionTests
```

Expected: 因缺少 `RealtimeDJSession` 类型而编译失败。

**Step 3: 实现最小合同**

增加：

- `RealtimeDJProvider`
- `RealtimeDJCapabilities`
- `RealtimeDJSessionTicket`
- `RealtimeDJContext`
- `RealtimeDJEvent`
- `RealtimeDJToolCall` / `RealtimeDJToolResult`
- `RealtimeDJSession` 协议

**Step 4: 重新生成工程并运行定向测试**

Expected: `TEST SUCCEEDED`。

### Task 2: 归一化百炼和豆包事件

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/Providers/Bailian/BailianRealtimeEventMapper.swift`
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/Providers/Doubao/DoubaoRTCEventMapper.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/VoiceSession/ProviderEventMapperTests.swift`

**Step 1: 写失败测试**

覆盖：

- 百炼服务端 VAD、字幕、响应和工具事件；
- 豆包 RTC 连接、首帧、字幕、工具和错误事件；
- 未知供应商事件被安全忽略。

**Step 2: 运行测试并确认缺少映射器**

**Step 3: 实现最小映射器**

映射器只解析类型和稳定字段，不包含网络连接、凭证或播放器逻辑。

**Step 4: 运行定向测试**

Expected: `TEST SUCCEEDED`。

### Task 3: 实现会话切换与迟到事件隔离

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VoiceSession/RealtimeDJSessionController.swift`
- Test: `apps/macos/Tests/GMGNRadioTests/VoiceSession/RealtimeDJSessionControllerTests.swift`

**Step 1: 写失败测试**

覆盖：

- 激活新会话会关闭旧会话；
- 切换供应商递增 `generation`；
- 旧会话迟到事件不会进入应用；
- 上下文、麦克风状态、打断和工具结果只发送给当前会话。

**Step 2: 运行测试并确认失败**

**Step 3: 实现最小 actor 协调器**

协调器持有当前会话和事件转发任务，所有供应商切换由同一入口完成。

**Step 4: 运行定向测试**

Expected: `TEST SUCCEEDED`。

### Task 4: 修订原设计并完成验证

**Files:**
- Modify: `docs/plans/2026-07-28-gmgn-radio-design.md`
- Modify: `docs/plans/2026-07-28-gmgn-radio-implementation.md`

**Step 1: 移除默认 LiveKit 与 ElevenLabs 流水线**

将实时语音改为 `RealtimeDJSession`，首批供应商为百炼和豆包。

**Step 2: 运行完整测试**

Run:

```bash
make test
```

Expected: `TEST SUCCEEDED`，零失败。

**Step 3: 检查差异并提交**

```bash
git diff --check
git status --short
git add apps/macos docs/plans
git commit -m "feat: abstract realtime DJ sessions"
```
