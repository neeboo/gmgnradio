# 本机 HTTP 与音乐存储

2026-10-07 用户授权：节目和歌单存入现有 Rust 后端的 SQLite；Rust 后端统一使用 HTTP；GPUI 启用 gpui-fast。

## 传输

`gmgn-taskd` 保留独占进程锁和单写入线程，只监听 `127.0.0.1`。私有端点描述文件版本为 2，包含随机端口和 UUID token；它仅用于发现服务，不承载音乐数据。所有请求通过 Bearer token 鉴权，拒绝浏览器 Origin，不开放 CORS。

| 路由 | 用途 | 返回 |
| --- | --- | --- |
| GET /health | 验证协议和服务 | version=2、transport=http |
| POST /rpc | 普通业务调用 | id 与 result/error |
| POST /events | 任务、消息、世界与语音订阅 | SSE：确认后按序发送事件 |

请求 JSON 保留现有 id/method/params 业务合同；不发送 body auth，不支持旧 NDJSON TCP 或 Unix socket。Swift 使用 URLSession，MCP 使用 reqwest；禁用代理、重定向和 cookie。请求/回复最多 12 MiB，事件流有界。语音使用随机 Client-ID 关联事件流与追加/提交/取消请求，断流清理所属语音会话。

MCP 只接受 `--endpoint-file`，授权文件必须包含 `endpointFile`；旧 `--socket` 参数和 `socketPath` 授权字段明确拒绝。权威生成的传输合同键为 `http_transport`。

DSH/Claude 的自定义宿主工具通道也统一为本机 HTTP `POST /rpc`：端点版本 2、Bearer token、每轮授权代次和 schema 校验。拒绝旧端点、浏览器 Origin、重定向、超限和慢请求，不保留裸 TCP/NDJSON 通路。外部 MCP/ACP/Codex 标准进程协议仍按供应商要求使用标准输入输出；语音供应商的流式协议不属于本机 taskd 传输。

## 同一份音乐数据

音乐表位于既有 `TaskService/tasks.sqlite3`，schema v5。客户端不直接打开 SQLite，也不再写节目或歌单 JSON 文件。

- `music_program_save`：完整 SavedDJProgram、pending 标记；成功回执表示事务已提交。
- `music_program_list`：完整节目及 pendingIDs。准备中的节目可跨重启恢复，但不会被当作当前节目自动播放。
- `music_library_read`：完整歌单及 revision。
- `music_library_commit`：完整歌单快照与 baseRevision；版本冲突明确失败，不覆盖另一客户端的更新。
- `music_import`：按 canonical 来源路径幂等、原子迁移；已有同 ID 记录保留，旧文件不改动。

两端从同一后端读取历史。Unity 工具保存等待数据库确认；原生界面使用串行异步持久化，失败可见。正式应用与隔离测试使用各自明确的 TaskService root，隔离测试不会导入真实用户数据。

## 迁移与验证

`tools/migrate-music-storage.py` 通过 HTTP 导入与逐条读回校验，不直接写数据库；可用 `--check-only` 再次核对。源文件 SHA-256 校验保证原始备份未变。参数 `--programs` 和 `--library` 可重复指定多个旧来源。

旧数据已在独立临时后台验证：11 个历史节目、417 个节目曲目条目、50 个歌单、200 个已缓存歌单曲目详情。重复迁移、只读核对与后台重启后的完整逐条读回均通过。

正式 `Application Support/gmgn radio/TaskService/tasks.sqlite3` 已备份并迁到 schema v5，上述完整音乐数据已通过鉴权 HTTP 导入并逐条精确读回。源文件 SHA-256 未变化，数据库 `quick_check` 通过；既有 8 个任务、11 个世界记录和 2081 个世界事实数量未变。新版界面显示与最终重启验收仍需单独记录。

实际部署及应用验收结果另写入 `2026-10-03-e2e-acceptance.md`，区分隔离测试、正式数据迁移与真实界面显示。此任务不修改节目调度提示或插播策略，不增加长期记忆或云端同步能力。
