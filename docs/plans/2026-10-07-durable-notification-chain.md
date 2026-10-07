# 生成／许愿通知链：消费与渲染确认

范围：现有 Rust taskd → Swift resident loop → Unity 预览回执。保留当前循环所有权；本轮不迁移模型循环，不新增任务提交、领取或摆放授权。

## 合同与顺序

- 每个事实保留原 `eventID`，任务保留 `taskID`，作用域固定为 `worldID/residentScope`。`publish_message` 相同 ID、相同内容幂等；内容冲突拒绝。
- `subscribe_messages` 重连从零重放未确认消息。`world/ui/agent` 独立确认；UI 已读、队列接受、模型开始均不代表 agent 已消费。
- 生成完成与渲染完成分开。`wish.outputReady` 发布及首次续办仍要求匹配当前预览的 Unity 渲染回执；声明 `completed`、模型文件存在或被加载均不足以确认渲染。
- 模型成功后，整批事件先在当前会话标记完成，再同步提交既有 `WishMachineCoordinator` 消费记录，最后异步 `ack_message`。确认失败只重试回执，不重跑成功模型回合。
- 重启后，已持久化消费记录对应的 daemon 重放只补 ACK，不再次进入模型。尚未消费的事件保留重投。
- 通知同步错误自动按 1、2、4、8、16、30 秒上限重试；成功重置延迟。关闭／换空间取消旧同步工作。重试不改变停止、预算、人类回合或编辑状态的自主授权约束。

## Unity 回执

预览描述新增 `projectionSessionID`（每次世界会话新建）与 `projectionID`（每次预览能力发布新建）。回执回传二者及 `worldID/wishID/objectID/modelPath`，带正整数 `receiptSequence`。

`rendered=true` 仅在模型激活、经过后续帧及 `WaitForEndOfFrame` 后发出，并携带正整数 `renderedFrame`。隐藏、卸载发出更高序号的 false。序号由 Unity 进程级 `Interlocked.Increment` 分配，设备重建不会归零；重复描述每秒可重报回执，无需重新加载模型。

Host 只接受当前 catalog 能力对应的会话／投影及身份，拒绝旧会话、已撤销能力、较低序号和同序号矛盾状态。渲染证据不持久化，重启必须重新获得当前帧证据。

## 验证

- Rust 消息单元测试 11 项通过；真实隔离 HTTP daemon 进程测试通过，覆盖重启重投、ACK 幂等、三个消费者独立、跨作用域拒绝及 failed/cancelled 类型保留，无 provider 调用。
- 生产 Swift 通知策略 23 项通过（传输/UI 替身）；真实 coordinator 档案测试通过（重启、部分写入失败、作用域、消费和发布标记失败）。
- 生产回执与重试策略 37 项通过；诊断隐私、设置及原 resident-loop 回归单列执行。
- 无签名 Host 动态库集成构建通过；Unity CLI 后台 C# 编译通过。C# 回执源级检查 4 项通过。
- 未替换、重启正式应用，未调用真实模型或生成服务；尚未完成正式 Player 中的加载／可见帧／通知续办验收。后台编译和 `WaitForEndOfFrame` 不能替代屏幕视觉验收。

## 剩余边界

模型／工具已经完成、消费记录尚未持久化时进程崩溃，仍可能重处理。文件写入失败时 coordinator 会封闭读取，`pendingDurableWrites`、`notificationError` 保留待确认状态；当前会话不重跑已完成回合，但不能承诺跨重启副作用恰好一次。未来 Rust 循环迁移应承接原事件 ID、消费确认和未知执行结果的核验规则，不能简单把未 ACK 解释为未执行。

生成任务订阅使用 taskd `messages`；`ResidentStateClient.message_read/message_ack` 使用独立的 `resident_messages`，不能混用游标或确认，也不能据本轮结果宣称所有 resident 消费入口已经闭环。

## 通用 inbox → agent 读取与反馈

本轮补充 `inbox.post`，要求 UUID `messageID`、非空 `title/detail`。通知正文和 `system_inbox` 唤醒消息通过同一 `state_commit` 原子提交；唤醒事件只带身份，不带正文。旧通知不会被自动重新发布。

Host 将事件送到现有 resident loop 的 continuation 入口。模型必须调用 `read_system_inbox` 从当前作用域的权威状态读取正文；读取证明绑定 `runID`，不修改人类的 `isRead`。只有同轮实际读取并成功返回反馈后才确认既有 `agent` 消费者，保持与 `ui/world` 的确认独立。

处理失败后按 5、15、30、60 秒主动重新提交同一消息。暂停、编辑或正在运行时不启动新轮，恢复后继续调度；既有模型最小唤醒间隔及每小时预算仍有效。成功后的 ACK 失败只重试确认，不再次执行模型。跨进程崩溃仍有“已产生反馈或副作用、ACK 尚未持久化”的窗口，不承诺副作用恰好一次。

验证：真实 Bridge/Storage/Client 回归通过；协调器重试 14 项通过；真实 resident loop + 协调器整合 7 项通过，覆盖首次失败、到期主动再跑、成功停止重试及 Rust/Swift UUID 大小写归一。该整合测试使用替代模型回调。

真实 taskd + 原生 DSH 模型验收脚本 `tools/test-unity-inbox-live.swift` 实测退出码 0：向隔离作用域投递一条消息，唤醒事件不含验收正文；模型实际调用 `read_system_inbox` 一次后回复 `INBOX_LIVE_78A6B493-AFB1-43B5-A092-2FBDFB689A08`；成功 ACK 后权威消息流为空，人类 `isRead=false` 保持不变。测试消息 ID 为 `D5DA8665-6E44-4044-8F64-75D42BB39335`，日志 `/tmp/gmgn-unity-inbox-live-test.log`。未替换正式 Player，也未进行音频播报或正式画面验收；本次验证覆盖真实后台、模型读取与文本反馈。
