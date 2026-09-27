# Rust 许愿任务后台设计与接口

用户决定：独立 Rust 后台进程承接异步任务，并发执行，通过异步通知驱动世界、界面、agent。此文替代旧计划 G 中的应用内 Task 执行方案。

## 最小架构

- `services/gmgn-taskd`：Rust/Tokio 独立可执行文件，单实例 Unix socket，SQLite 单写持久任务及事件，默认最多 2 个任务同时处理远端请求。后台不依赖 AppKit、DSH 或聊天轮次；客户端断开后已受理任务继续。
- `PropGenerationStore`：保留 Swift 对外接口，改为后台客户端及只读任务快照。不再直接调用远端生成 API 或写旧 `tasks.json`。
- `WishMachineCoordinator`：应用内持有愿望授权、世界/居民归属、领取/摆放委托与通知确认，独占 `wishes.json`；从后台任务快照推进阶段。
- 主应用订阅后台事件并投影到世界、界面、agent。生成文件通过校验与渲染就绪是不同阶段；仅真实 renderer ready 可授权领取。
- 图像格式适配暂复用 macOS ImageIO（含 HEIC、EXIF 方向和去元数据），输出不超过 8 MiB 的 PNG 后提交本地队列；远端等待、提交、查询、取消、下载均在 Rust 进程内。不得用应用内异步网络任务代替后台。

## 进程与存储

命令：`gmgn-taskd --root <absolute-private-directory> --socket <absolute-socket-path> --concurrency 2 [--legacy-root <absolute-PropGeneration-directory>]`。

默认根：`~/Library/Application Support/gmgn radio/TaskService`；socket 为根内 `taskd.sock`。目录 0700、数据库/图片/模型/socket 0600；持有进程锁后才移除确认过的旧 socket。第二实例不能抢占运行中进程。

Rust 独占新目录下数据库、任务 PNG/GLB、事件。Swift 不直接编辑这些文件。旧 `PropGeneration/tasks.json` 只读导入；保留原文件和素材。导入已有远端回执继续查询，未确认提交不自动重发；迁移必须幂等，错误不得当空库覆盖。

凭据只通过本机 socket 配置，常驻进程内存保存，禁止命令行参数、日志、数据库和事件含 token。后台重启后没有对应 origin 凭据则等待配置，不用其他服务的凭据。客户端断开不取消任务；用户显式取消单独持久化。

## IPC v1：Unix socket 上的 JSON Lines

每行一个 JSON 对象，收发最大帧均为 12 MiB。请求 `{"id":"request-id","method":"submit","params":{...}}` 的 `id` 必须为 1—200 UTF-8 字节字符串；成功 `{"id":"request-id","result":{...}}`；失败 `{"id":"request-id","error":{"code":"stable_code","message":"safe message"}}`。无效请求 ID 以 `id:null` 和 `invalid_request_id` 拒绝，不回显超大或非字符串数据。

- `configure`：`{endpoint, token}` → `{configured:true}`。仅 HTTPS origin 或 loopback HTTP，无用户名、密码、路径、query、fragment；禁重定向和凭据转发。
- `submit`：`{id, endpoint, name, pngBase64, source:{author,license}, heightMeters}` → `{job:Job}`。id 为已有 wish/core UUID，也是 Idempotency-Key；相同 id+相同请求返回原任务，不产生第二次提交，相同 id+不同请求拒绝。先校验 PNG、持久 PNG+任务+事件，再返回受理；不等远端 POST。
- `snapshot`：首帧 `{}` → `{jobs:[Job], sequence:integer, nextCursor?:string}`；若有 `nextCursor`，用 `{cursor:nextCursor}` 继续取页。每页不超过 2 MiB；所有页均为首帧 `sequence` 时刻的完整一致快照，末页省略 `nextCursor`。游标不透明，可跨连接续取；客户端合并全部页后一次投影，并从该固定 `sequence` 订阅后续事件，避免取页期间状态变化丢失。
- `retry`：`{id}` → `{job:Job}`。仅重试原幂等提交或原任务可恢复下载；不创建新身份，不自动重试已明确失败的生成。
- `cancel`：`{id}` → `{job:Job}`。保存请求再返回，忙时不能丢失；未提交的排队任务可本地取消，已提交则发取消请求并持续查终态；cancel_requested 不等于 cancelled。
- `subscribe`：`{after:integer}` → `{subscribed:true}`，随后连续 `{"event":{"sequence":integer,"job":Job}}`。持久事件序列单调，先重放 after 之后的事件再接实时变化，不漏重放与订阅切换窗口。重复允许，按 sequence 去重；写入落盘成功后才能发送。

Job 沿用 Swift `PropGenerationRecord` 的 camelCase JSON：

`{id,name,endpoint,imagePath,imageSHA256,heightMeters,source,idempotencyKey,receipt?,localModelPath?,lastError?,backendStage,cancelRequested}`。

- `id` 可解码为 UUID；`imagePath/localModelPath` 是 Rust 私有任务目录内的绝对路径，仅在文件实际落盘且校验通过后发布。
- `receipt` 原样保持现有远端 snake_case schema，Swift `PropGenerationReceipt` 解码；已知远端 ID 必须匹配请求，不丢弃结果 inspection/source 等字段。
- `backendStage`：`queued, submitting, submission_uncertain, awaiting_configuration, running, downloading, ready, failed, cancel_requested, cancelled, interrupted`。
- `ready` 只表示已校验 GLB 本地可读，尚不表示在场景中可见。
- 出错保留原身份及已知回执。请求不确定时不自动重发；用户 retry 复用原 Idempotency-Key。恢复 running/downloading 继续原任务。

## 远端与安全边界

## 补充：Rust 持久异步消息收件箱

用户追加要求异步消息也交给 Rust。任务快照流保留用于缓存同步；业务通知统一由 Rust 持久消息管理，不由 Swift 维护另一套投递队列。

- `publish_message`：`{id,taskId,worldID,residentScope,kind,payload}` → `{message:Message}`。id/taskId 为 UUID，taskId 必须存在；同 id+同全部内容返回原消息，同 id+不同内容拒绝。kind 白名单为 `task.stateChanged`、`wish.stateChanged`、`wish.generationCompleted`、`wish.outputReady`、`wish.failed`、`wish.cancelled`、`wish.interrupted`、`wish.claimed`、`wish.placed`。payload 为最大 64 KiB JSON object，作为数据处理，不能当工具指令。
- `subscribe_messages`：`{consumer,worldID,residentScope}` → `{subscribed:true}`，随后 `{"message":Message}`。consumer 仅 `world/ui/agent`；从持久库重放该范围内此 consumer 尚未确认的消息，再推实时变化。连接内同 message 一次即可，重连可重复，由 id 去重。一个 consumer 确认不影响另外两个。
- `ack_message`：`{id,consumer,worldID,residentScope}` → `{acknowledged:true}`。严格匹配消息范围，重复确认幂等，其他范围不能确认；消费成功之后才发确认。agent 忙碌时不确认、消息留存；成功处理后的 ACK 失败只重试 ACK，不重新执行业务动作。
- Message：`{id,sequence,taskId,worldID,residentScope,kind,payload}`；sequence 单调持久。
- Job 新增可选 `context:{worldID,residentScope}`；submit 同名可选参数。新许愿必须传，旧无范围记录不自动猜范围或向所有agent广播。后台状态变更在同一持久事务生成 `task.stateChanged` 消息（有context时）；App 渲染/领取/摆放事实使用 publish_message，仍与原 wish_id 关联。
- Coordinator 原事件记录可保留为业务事实和迁移来源，以稳定 event.id 幂等 publish；不再把其内存轮询当作消息运输或最终投递确认。Rust 是三路投递、待收与确认的唯一持久归属。
- 消息不会自行恢复已被用户撤销的自动行动授权。通知可以留存；世界动作、agent续办仍由应用现有scope/暂停/工具授权门处理。

模块分工：`src/messages.rs` 由独立 Rust 消息 worker 持有，只实现在既有 rusqlite Connection/Transaction 上的 schema/publish/pending/ack 方法和单元测试；不自建第二数据库或第二writer。主 Rust worker负责actor命令、socket路由和任务状态事务接入。模块接口由两worker直接确认；任何公共JSON变化先同步Swift桥。

追加验收：同一消息三消费者分别收到；ui ACK 后 world/agent仍待收；agent忙碌或断线消息保留；重启后未ACK重投；错误scope拒绝ACK；重复publish不产生第二条；更改同ID内容拒绝；任务状态事务和消息不能分裂。

## 远端与安全边界（续）

沿用 `PropGenerationClient.swift` 的实际远端合同：POST `/v1/jobs` JSON `image_base64/name/source/height_meters`，Idempotency-Key 为任务 UUID；GET `/v1/jobs/<32lowerhex-id>`；POST `/v1/jobs/<id>/cancel`；下载只能同 origin 的 `/v1/jobs/<id>/model.glb`。

60 秒请求超时、状态响应最多 1 MiB、PNG 最多 8 MiB 且尺寸 1..2048、模型最多 32 MiB（流式上限）。GLB magic/version/declared length、远端 inspection bytes/SHA256 必须匹配。拒绝重定向、路径逃逸、符号链接任务素材、NaN/非法高度及不合法返回 ID。不要将错误响应体或配置 token 放进事件。

远端 GPU 仍受原服务串行资源限制；Rust 允许不同任务的提交、等待、下载并行，不修改 GPU worker 并发能力。

## 实现分工

- Rust worker：独占 `services/gmgn-taskd/**`，负责后台、队列、网络、事件、进程回归。接口不自行更名；变更先通知 Swift worker 和主代理。
- Swift bridge worker：独占 `Presence/PropGenerationStore.swift`、新 `Presence/PropTaskDaemonClient.swift` 与独立客户端回归，维护已有 UI API 兼容、启动/连接/订阅/断线恢复。常驻 helper 缺失要明确报错，不偷偷退回应用内网络。
- Wish worker：独占 Coordinator/Tools，移除应用内网络调度中间方案，以 facade 的 durable queue ACK 和快照推进；保留授权/领取/摆放与状态事件。
- UI worker：独立 task presentation，不写后台或业务存储。
- 主代理：App 事件接线、cursor/ack语义、项目和构建/打包；离线验收前不启动真实业务后台。

## 验收

必须有真实子进程+本机假 HTTP 服务的集成回归：两个任务提交不等远端；两个请求确实重叠；客户端断开后继续；第二实例拒绝；终态事件推送且重连重放；服务重启/幂等重试不重复创建；取消忙时持久保留；坏响应/重定向/超限/校验失败不得 ready；凭据不落盘。Swift 回归验证同任务快照到 Coordinator、世界、UI、agent，结果通知不占原聊天轮次。

不启动 gmgn radio 宿主，不调用真实模型、生产生成服务或系统授权。最终分别报告后台离线进程验证、构建/安装、尚未执行的宿主视觉验收。
