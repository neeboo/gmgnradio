# 全部近期任务续办：居民设置、用量、工具后端与运行交付

日期：2026-09-12。状态：本批实现、离线回归和统一安装完成；真实服务/宿主验收及文末明确缺口仍未完成。

用户明确要求继续推进全部已授权任务。总清单为
`docs/plans/2026-09-12-current-delivery.md`，同时核对第一阶段和许愿机完整交付计划。
此次审计确认了居民人格、可设预算、可查询用量、其他后端世界工具这几项真实漏实现，
不再把最近的长期记忆配置报错当成唯一任务。

## 实现与验证分工

- 应用生产代码和脚本由真实 `dsh --profile headless` 编码；各原生代理负责限定范围、
  审阅与测试；主代理独立检查跨项接线和回归。未把启动编码进程当成完成。
- 不运行应用宿主、窗口自动化、GPU 验收、Keychain、真实语音或付费生成。
- 所有协议测试使用隔离目录、临时套接字、隔离偏好或明确替身；不写用户实际数据库。
- 未整批暂存/提交已有脏工作树；不回退其他协作者的修改。

## 当前验证记录

### App 后台预算接线

主代理新增 `tools/test-resident-autonomy-preferences-app.swift`，抽取实际
`refreshResidentAutonomy()` 编译执行，隔离宿主依赖及用户默认设置。

- RED：预算尚未应用时退出 1，6 项检查中 5 项失败。
- DSH 在 `ensureResidentLoop()` 后、记忆恢复门限前接入保存的预算。
- 主代理独立 GREEN：退出 0，6 项通过；覆盖首次应用、热更新、恢复门限、编辑与后端支持门限。
- 该测试只证明 App 正确传递设置；循环计数、额度消费和偏好持久化由另外的真实类型测试验证。

### 长期记忆配置恢复

- 首批修复：缺显式环境配置后继续按 30 秒节流核对，进行中不重复请求；外部配置恢复后替换旧提示。
- 主代理独立复跑首批 11 个场景、134 项通过。
- 独立审阅随后发现两个 P2：旧“配置失败”提示恢复遗漏、跨空间/重新绑定的异步返回隔离。
  两项均由 DSH 加失败测试后修复。
- 主代理最终独立运行 `swift tools/test-resident-conversation-memory-config-app.swift`：
  退出 0，24 个场景、226 项通过。每次异步状态/配置返回均核对当前 scope、绑定代次和取消，
  旧状态不覆盖新空间；外部恢复清除配置失败提示，后台真正故障继续可见。

### 居民人格、预算偏好与用量

- 居民人格使用独立 `resident.persona.v1`，未复用 DJ 主持偏好；统一在每轮居民 prompt
  组装时读取最新值。人格段不改变宿主工具授权。偏好类型放在既有 Service 编译单元，
  已清理临时独立类型及首轮追加的失效编译路径。
- 设置提供 0...6 的后台思考预算，默认 6；保存后发出现有自主设置通知，由 App 应用到现有 loop。
  0 不取消当前轮，只阻止再发起后台思考；调低预算不清已消费轮数。
- 主代理独立运行 `swift tools/test-resident-preferences.swift`：退出 0，34 项通过；
  `swift tools/test-resident-conversation-tools.swift`：退出 0，20 项通过。
- `read_resident_state` 沿用现有正式出口，增加总模型轮数、后台轮数、失败轮数、取消轮数、
  滚动小时用量和当前限额。统计只在当前 ResidentAgentLoop 实例内保留，不是 HTTP 次数或计费量。
- 主代理最终独立运行 `swift tools/test-resident-agent-loop.swift`：退出 0，236 项通过。
  覆盖调用前即停零消费、旧轮迟到、结果已返回但 steering 未完成时不漏计/双计，
  以及无控制权空回复计失败、未启动后台轮次遇预算下降时保留事件/续办/人类输入。
  失败呈现仍等既有 steering 结束，不因用量统计提前；原有前台消息不会被预算阻塞。
  最终日志：`/tmp/gmgn-final-resident-loop-20260912.log`。
  原测试的 `wakeLoop` sendable capture 编译警告仍存在，未修改无关测试逻辑来消除它。
- 跨项独立回归：记忆服务 79、居民路由 20、计划恢复重试 71 项均退出 0。
  日志分别为 `/tmp/gmgn-final-memory-service-20260912.log`、
  `/tmp/gmgn-final-conversation-tools-20260912.log`、`/tmp/gmgn-final-restore-retry-20260912.log`。
- 新增 Claude 分支后，主代理运行 `bash tools/test-resident-dsh-service-native-assembly.sh`：
  退出 0，37 项通过；真实安装的 DSH ACP runtime 连接隔离 loopback 模拟 provider，
  实际 Service 同 scope 多轮工具调用、取消和恢复通过。未使用真实模型或真实凭据。
  日志 `/tmp/gmgn-final-dsh-service-20260912.log`。

### 原安装入口与长期记忆配置

- 复用 `tools/install-macos.py`，没有新建 App 启动器。正常 `make install` 在
  双 provider 环境配置完整时，安装并核验后台后配置服务并读回状态；配置全缺时允许
  安装，但回执明确 `memory_configured=false`；部分配置在替换/停止任何进程前拒绝。
- 已安装后台可用 `python3 tools/install-macos.py --configure-memory-only` 配置，
  该模式不构建、不替换包、不启动或停止 App/后台。
- 调用前需由获授权的环境提供 `GMGN_MEMORY_COMPACTION_ENDPOINT`、
  `GMGN_MEMORY_COMPACTION_TOKEN`、`GMGN_MEMORY_EMBEDDING_ENDPOINT`、
  `GMGN_MEMORY_EMBEDDING_TOKEN`；两项对应的 `_MODEL` 可选。脚本不会读取聊天密钥
  或钥匙串，不保存凭据；后台重启后需要重新配置。
- 发送凭据前同时核对 socket 对端 PID、精确后台命令和内核 `proc_pidpath`
  返回的实际可执行文件；安装模式还核对新启动 child PID。原始服务错误不写入回执。
- 主代理独立运行 `python3 tools/test-install-macos.py`：退出 0，32 项通过，
  覆盖双配置读回、缺项无副作用、伪造命令/实际程序不符零凭据发送及错误脱敏。
- 当前缺少两套服务的显式环境配置，测试使用本地协议 fixture；没有向实际后台配置
  假凭据，也没有证明真实整理/向量质量。

### Claude 受限工具桥

- 新增 Claude Code 专用 stdio MCP adapter，复用现有会话级 UDS 通道；
  每项工具精确授权，固定启动时的 secret/round，旧 adapter 不能因重授权恢复权限。
  授权到期、取消或回包时失效均拒绝迟到结果；图片按 MCP image content 返回。
- 主代理最终独立运行 `swift tools/test-resident-claude-tool-bridge.swift`：
  退出 0，163 项通过。日志 `/tmp/gmgn-final-claude-bridge-20260912.log`。
  该协议测试不单独证明实际 App 的 33 工具或真实模型已可用。
- 主代理独立运行 `swift tools/test-resident-claude-prepare-failure.swift`：退出 0，
  初始化失败后本次私有目录及 marker 均已清除。测试在临时源码副本的唯一 prepare
  调用点注入错误，生产没有增加测试入口；未修改既有 DSH 通道。
  日志 `/tmp/gmgn-final-claude-prepare-20260912.log`。
- 主代理在所有写入结束后的稳定快照独立运行
  `swift tools/test-living-resident-loop.swift`：退出 0，223 项通过。
  保留原 199 项 App 方法闭环检查，新增 Claude 实际 33 工具 schema 组装、
  取消/换空间、无持久 session ID 的内存历史与重置检查；未跳过 Claude。
  日志 `/tmp/gmgn-final-living-loop-20260912.log`。
- 主代理最终独立运行 `swift tools/test-resident-claude-service.swift`：退出 0，
  260 项通过，Swift 6 真实编译执行。日志 `/tmp/gmgn-final-claude-service-20260912.log`。
  链路为实际 Service → 隔离测试 CLI → 生产 Node MCP adapter → 生产 UDS →
  当前工具处理器 → MCP 回包 → CLI JSON 结果；没有启动真实 Claude 模型。
- Claude 每轮使用新的私有工作/配置目录和 `--bare`、严格 MCP、禁内建工具/额外
  设置/持久会话的参数；只逐项允许当前工具。环境白名单剔除 Node preload 等注入，
  只接受显式 `ANTHROPIC_API_KEY`，缺失即在进程启动前固定失败。
  对话连续性使用按 scope 隔离的有界内存历史，不借用旧 Claude `--resume`。
- 输出必须是合法成功结果，畸形 JSON、缺 result、错误终态和错误字段类型不能被
  当作静默成功；合法空回复仍按实际控制权判断。人格每轮重新读取，长期记忆按 fresh
  会话召回，耐久记录仅使用实际用户文本。
- stdin/stdout/stderr 均有可取消非阻塞边界；输出超限固定失败。取消/超时只终止并
  回收自有直接子进程，关闭自有管道并等待收尾；不杀进程树或未知 PID。受控后代持有
  管道、忽略 TERM、1 MiB 输入、环境 preload、在途工具取消和替换均有行为回归。
- 所有独立审阅发现的 P2 已修复并验证；最后输入写端先以 260 项中 2 项失败复现，
  修复后 260 项全过。此前边读源码边编译的中间态失败已由稳定快照复跑取代，未掩盖。

## 本批统一安装及产物核验

- 主代理运行 `make install`：退出 0，`BUILD SUCCEEDED`，无签名构建；应用和
  配套后台通过原入口统一更新。日志 `/tmp/gmgn-resident-completion-install-20260912.log`。
- 安装位置 `/Applications/gmgn radio.app`；回执为 `daemon_verified=true`、
  `app_stopped=false`、`open_app_manually=true`。没有打开宿主窗口或运行真实模型。
- 安装和构建主动态库 SHA-256 一致：
  `3a640e17682b9ce34584117716d3b3f1744c01d319951918bfe9121b81d9d0a4`。
- 安装和构建后台 SHA-256 一致：
  `493876f38b3f686f24dfcea1d39a2dcf5ea713cec78fe4f3ae8f445df73ae205`。
- 额外只读核验 socket 对端 PID `29713`：精确命令及内核实际可执行文件均匹配
  安装目录的 helper。有效 `memory_status` 读回 compaction/embedding 均为 false。
  未配置假凭据、未执行模型请求、未写用户记忆。
- 安装回执明确 `memory_configured=false`、`model_quality_verified=false`，缺少四个
  显式必填环境变量。配置通道已交付，不代表两套真实服务已经提供或验证。
- 按已有清理授权，精确移动本次安装回执中的旧备份及重复构建 App 至
  `/Users/ghostcorn/.Trash/gmgn-replaced-packages-Z8sKSF/`，分别为
  `previous-installed.app` 和 `duplicate-build.app`，可恢复；正常安装目录保留新版。
- `git diff --check` 退出 0，仅现有 LF/CRLF 提示；没有整批暂存/提交脏工作树。

## 明确未完成的运行验收与缺口

真实 provider 质量、宿主画面、声音、持续生活以及同一次模型委托到生成摆放的运行验收，
继续与离线实现和安装分别报告。WorkBuddy、Qoder、pi 未在本次相关本机路径检查中找到可用 CLI，
不将其标为已支持正式世界工具，也不代用户安装或改变身份配置。

### PMX 口型的真实实现缺口

独立只读审阅确认当前 2B 资产 `na_2b_0414.pmx`（manifest 4.14.0）156 根骨骼中
没有下颌/嘴部控制骨。现有面部路径依赖 `SCNMorpher`，被
`PMXMaterialCompatibility.swift` 因首帧渲染崩溃风险禁用；渲染器也移除 VMD morph 轨道。
因此不能通过补一条语音权重接线完成 PMX 口型，也不能将它归入“仅待试听”。
旧危险路径未恢复。安全替代需要另行实现和真实渲染验证，当前未完成；VRM 的实现和
CPU 断言不能替代这一证据。更多 TTS 后端按任务 6A 的原先依赖继续后置。
