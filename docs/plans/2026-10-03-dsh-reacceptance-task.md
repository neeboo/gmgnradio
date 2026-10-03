# DSH 返工与主代理验收

用户明确要求：主代理负责验收，不合格就让 DSH 持续修，不能只汇报未验。

用户再次明确：验收是端到端，不是只看单测。必须使用当前构建的真实 App（可隔离数据根），将用户输入、真实服务调用、资产加载、世界操作与实际画面/声音连成一次业务流程。源码切片、fixture服务、独立AVPlayer/WKWebView探针和单测不能代替最终验收。自动化不具备的宿主操作需要暴露可测入口或提供具体操作路径给主代理，不能仅重复权限限制。

主代理已于本轮在宿主执行 make build，退出码0，日志 /tmp/gmgn-parent-reacceptance-build-20261003.log。这是返工前基线构建；DSH后续修改仍须重新构建。

## 当前拒收项

### 主代理连续验收最新结果

全新根1838真实生成完整脚本运行结束，exit2，114pass/0fail/1blocked（日志 `/tmp/gmgn-parent-fresh-e2e-1838.log`）。真实新生成任务 `1536D3FF-C7DE-4C18-BC04-9529E7E3B2F2`，实际领取入库/摆放/手持放回/人物三类动作/电视真实GPU视频/通知未读转已读及重启已读/真实chat delivered通过。唯一脚本阻断仍是HLS声音采样；不能标整体验收通过。仍需实际App非HLS声音对照与HLS输出证据，并增强重启后物件摆放/屏幕内容恢复readback（已有脚本仅验世界加载/通知/接地，不可夸大）。重启最低接触点3.55m虽未穿地，浮地/姿态视觉尚需核对，不能仅凭单边接地断言关闭视觉验收。

主代理已启动全新隔离根 `/tmp/gmgn-e2e-20261003-1838`，显式COPY只读PMX人物和四个BONES动作包，无existing-wish-id，日志 `/tmp/gmgn-parent-fresh-e2e-1838.log`，session99575。三类真实动作已通过，进入真实生成阶段；后续等待同一次业务链领取/摆放/电视/通知/重启/chat，不将尚在运行计为通过。当前已推送HLS停滞修复与边界文档（baf93f4、e604f4b），DSH实现轮已停止，主代理继续验收。

18:35 主代理当前1833宿主构建 exit0，真实App恢复运行 exit1，102pass/1fail/2blocked（`/tmp/gmgn-parent-reacceptance-1833-real-app.log`）。HLS停滞已实际消除：decoded11→74/time+2.089s，GPUdraw177/quads177/fragments736497；后来实时读回decoded443/rate1/noError。三类动作/摆放/手持放回/重启接地与真实chat delivered通过。声音采样仍unsupported:hls-manifest阻断，不当作通过；旧任务已读导致本轮无新未读通知，翻转与重启已读判据不能空跑。继续DSH真实声音证据返工，并按用户授权提交推送当前修复检查点，最终仍须全新生成完整流程。

用户最新明确授权「所有的修改都要提交推送」。本次按两个现有分支分别提交推送主仓库返工与独立Bevy原型，不合并、不替换引擎。此授权取代此前本任务禁止commit/push的边界；禁止reset、清生产数据、Keychain操作和覆盖已装App继续有效。提交是当前进度检查点，不代表完整端到端验收通过。DSH音频返工已暂时停止以稳定提交快照，推送后继续返工。

18:14 chat安全诊断版当前宿主构建 exit0（`/tmp/gmgn-parent-reacceptance-1813-build.log`）；真实App对话专项复验 exit0，7pass0fail0blocked，日志 `/tmp/gmgn-parent-reacceptance-1813-chat.log`。真实输入进入可见历史/sendEnteredCount/modelTurnsStarted，收到delivered终态。此前failed未复现，不能凭此认定原始根因已修；安全诊断保留用于后续复现。该专项运行不计为生成/声音/完整流程通过。DSH音频停滞返工已自动启动，日志 `/tmp/gmgn-dsh-audio-stall-1810.log`，当前查HLS真实tap兼容边界。

18:10 崩溃修复后的真实恢复运行结束，exit1，83pass/2fail/1blocked；`/tmp/gmgn-parent-reacceptance-1806-real-app2.log`。行走/跳跃/坐下按clip+epoch真实时钟、骨骼姿态和接地全部通过；摆放手持放回及重启接地通过。电视新tap接线造成实际停滞仍拒收。无新未读通知导致翻转不能复验；本轮显式skip-chat。DSH当前先完成chat安全诊断，随后已排队串行音频停滞返工，日志 `/tmp/gmgn-dsh-audio-stall-1810.log`（队列等待时文件尚不存在），主代理继续负责实际构建复验。

18:09 当前真实App不再崩溃，但实际播放读回 surface=playing/decodedFrames=1/rate=0/currentSeconds=16；tapAttached=true/installDetail=all-tracks，真实 sampledAudioBuffers22/frames98428/peak0。存在真实音视频停滞，不能以tapAttached或缓冲计数宣称声音通过；必须排查tap直通、处理格式及HLS协商，保留真实App复验。

18:07 崩溃后恢复驱动又遇旧quit命令重放，未产生新ips，确认control/inbox残留quit。主代理在 AppHost.launch 将旧inbox/outbox JSON移入测试evidence/stale-mailbox保留，禁止新实例执行旧命令；已重跑 session48553，日志 `/tmp/gmgn-parent-reacceptance-1806-real-app2.log`。全部只作用于隔离测试根，未清用户数据。

18:06 主代理移除 NativeAudioSampleTap.install 的 @MainActor，防止C回调继承隔离；宿主构建 `/tmp/gmgn-parent-reacceptance-1806-build.log` exit0，真实App局部恢复复验运行中，日志 `/tmp/gmgn-parent-reacceptance-1806-real-app.log`。DSH已聚焦真实chat安全诊断返工 session6795，日志 `/tmp/gmgn-dsh-chat-diagnostics-1806.log`；停止旧10602避免其继续修改正在复验的音频链。

18:04 音频接线版真实App在播放退出，driver session57023 exit1且未到终态ledger，日志 `/tmp/gmgn-parent-reacceptance-1803-real-app.log`。已查真实系统崩溃报告 `/Users/ghostcorn/Library/Logs/DiagnosticReports/gmgn radio-2026-10-03-180453.ips`：EXC_BREAKPOINT/SIGTRAP，thread15 `_dispatch_assert_queue_fail`→`_swift_task_checkIsolatedSwift`→`NativeAudioSampleTap.install(on:track:) closure #3`，音频回调继承 @MainActor 导致音频线程隔离断言，必须修且不能禁采样冒充通过。对话只读审计确认Codex会话真实启动并继承HOME/CODEX_HOME，未因隔离根缺少配置；ResidentCodexAgent已有failureStage/Code/Category/Detail，但AgentConversationService.sendResident清currentResidentAgent时丢失这些字段，应安全保存再暴露给E2E，不输出stderr/认证配置。

18:03 音频接线改动后主代理宿主构建再次 exit 0（`/tmp/gmgn-parent-reacceptance-1803-build.log`），真实 App 恢复复验已启动 session57023，日志 `/tmp/gmgn-parent-reacceptance-1803-real-app.log`。本轮显式skip-chat-turn，先核对声音修复，禁止将该局部恢复运行计为完整验收。DSH仍在修播放epoch/真实对话问题。

17:56 当前真实恢复流程 exit 1：93 pass / 3 fail / 3 blocked，`/tmp/gmgn-parent-reacceptance-1753-real-app.log`。实际电视帧1→48、播放时钟+1.704s、render drawPasses119/quads119/fragments398888，摆放/手持放回通过；行走和跳跃真实姿态通过，坐下姿态变化及接地通过但sceneTime跨重置(-0.395s)失败；重启接地通过。声音 MTAudioProcessingTap 未挂上，不能算声音通过。真实用户文本经生产提交门进入可见历史/对话服务/模型轮次，终态failed、replyText空，lastFailure「居民未能完成本轮回复，请重试」。复用旧通知全已读，本轮通知翻转阻断，前轮53pass运行确实验证过。初始decodedFrames=1与后续48造成门槛时序误报，主代理已将wait_screen_playing改为>=2，保留后续连续增长断言。需DSH修声音真实采样、坐下按clip分段时钟判据和真实对话失败，最后用新隔离根进行全新生成完整流程。

17:53 再次宿主构建 exit 0（`/tmp/gmgn-parent-reacceptance-1753-build.log`），真实 App 已运行（session 42075，`/tmp/gmgn-parent-reacceptance-1753-real-app.log`）。本轮已实际通过骨骼姿态采样的行走、动作接地、生产预检选点摆放、手持放回和电视播放工具接受。坐下播放时钟跨度 -0.395s 仍失败，不能删断言宣称通过；需判定 clip切换/循环时钟语义或真实倒退。电视画面声音、聊天和重启结果仍在等待。

17:38 最新完整恢复运行 exit 1，53 pass / 6 fail / 0 blocked，日志 `/tmp/gmgn-parent-reacceptance-1740-real-app3.log`，ledger `tmp/e2e-real-app/ledger.json`。通知已读及重启恢复现已真实通过，库存/手持/放回通过。拒收项：选第一层摆放报 placement_rejected「这里会插进墙或家具」；play_screen 报 screen_not_found，功能绑定/摆放后识别未完成；重启 minimumContactY=-5.026019、contactLiftY=5.110890、groundingOffsetY=0，补偿字段语义或真实接地未闭环。另两条动作失败是错误指标：avatarFrameRevision 取 StageAvatarRuntime snapshot.revision，资源选择版本并非动画帧，禁止仅改为GPU frameIndex就宣布骨骼运动通过。需逐帧暴露 PMX 实际 clip/player/sceneTime/presentation骨骼角度并验证姿态变化。坐下、声音、真实聊天输入仍未验。

17:35 宿主当前树构建成功（`/tmp/gmgn-parent-reacceptance-1740-build2.log`，exit 0）。主代理修复 claimEvidence 非可选值误用 optional chaining，以及采样闭包显式 @MainActor/@Sendable 返回类型。真实 App 恢复运行已通过下载检查、托盘ready、居民取物活动、领取、实际库存入库，承托层3136层。driver 因 center 为数组误用 .get 崩溃，主代理已修并加入已领取任务恢复分支，继续真实运行 `/tmp/gmgn-parent-reacceptance-1740-real-app3.log`。行走与跳跃真实入口已执行，但 avatarFrameRevision 始终1，尚不能证明骨骼动作播放，不算动作通过。

主代理已启动当前树宿主重构建，执行 `GMGN_BUNDLE_SCREEN_LINK_HELPER=1 bash tools/e2e-app-build.sh --print-path`，日志 `/tmp/gmgn-parent-reacceptance-1740-build.log`。不再仅等待 DSH 的自报完成。新 driver 已有显式已有任务恢复模式，本轮先复用真实生成任务 `474AC5DE-3A7D-49A4-88D4-F09902F11DF5` 检查后续业务链；该恢复运行不计作新生成/完整聊天通过。

17:22 跟进：第一轮 DSH 安全测试根、复制资产、真实活动入口返工已结束；第二轮领取/入库/通知恢复返工已自动接续，日志 `/tmp/gmgn-dsh-claim-restart-fixes-20261003.log`。主代理已审阅新 driver，确认走正式 start_activity，当前世界坐下活动缺失仍须记录未通过。第二轮结束后须重构建当前树，并优先复用此前真实生成任务；复用不能代替新生成与聊天回合验收。电视声音、完整聊天输入、坐下与重启物件/屏幕恢复仍是最终验收门槛，不能仅凭增加动作断言或编译通过关闭。

最新带真实资产运行（`/tmp/gmgn-e2e-20261003-1710`）完成，exit 1：29 pass / 2 fail / 1 blocked。真实服务产出 GLB 4,950,064 bytes。不能按通过数量算完成：claim 后 read_owned_props.objects=[]，list_placement_surfaces.surfaces=[]，摆放/手持未执行；电视未实际进入播放；重启后找不到已读通知记录（虽未读数0）。当前 ledger 为 tmp/e2e-real-app/ledger.json，日志 /tmp/gmgn-parent-real-app-assets-20261003.log。
主代理又修 driver 的 tool()，把内层 isError/ok=false 传播为失败，避免只看外层邮箱 ok=true 把 play_screen 误报接受；生成超时现返回None，禁止继续当作已生成。
下一轮必须修物件领取/实际入库/支持表面接线、电视实际播放与重启通知恢复，再触发真实动作（当前只idle）与界面许愿提交（当前实测通过正式生成工具，未走完整聊天agent回合）。

- 当前独立测试 App 已构建成功，内置 taskd / MCP / yt-dlp 校验通过。
- 长默认 root 的真实 E2E：4 pass / 6 fail / 2 blocked，世界未加载。
- 短 root `/tmp/gmgn-e2e-20261003-1707`：9 pass / 4 fail / 2 blocked，世界加载及真实GPU连续抓帧成功；无人物导致接地诊断缺失、画面摘要不变化。
- 生成失败为本轮授权未传递：`wish_operation_failed` / 本轮没有用户授权的图片生成请求。不是服务凭据失败。主代理已补 e2eWishAuthorizationID 的注册与 submit 工具租约传递，正在重新构建。
- 主代理已修 driver 错误分支 `Ledger.blocked` 的 message 重复参数，改成 providerMessage。DSH不得回退这些最新修改。
- 后续先复用实际用户人物/动作包的只读资产，保持写入在测试根；继续真实生成到最终完整流程。

1. 当前树完整 App 构建未确认。历史成功产物不是当前代码构建证据。
2. yt-dlp 网站链接原生播放先前实现已整体回退；用户已经选定链接优先、yt-dlp，不可把回退当完成。
3. 真实宿主用户流程未验：真实生成任务、权威入库、摆放/手持、电视画面与遮挡、通知已读、重启恢复。
4. 人物动作穿地未有真实画面验收；Twitch 自动播放和 B 站黑屏未关闭。
5. MCP helper 和链接解析 helper 的生产打包、安全校验与许可告知未完成；电视内容和标定 persist 回调为 nil。

## 实施边界

继续当前 macOS 客户端，不替换引擎、不扩大 Windows/Unity/Bevy 工作。
维护唯一 taskd 世界状态写入者。保护 dirty worktree，尤其 tools/world-backup 与他人修改。
不使用 git add -A/reset/checkout --，不回退别人的代码，不 commit/push。
链接只访问用户授权的公开来源，不读取浏览器 cookie/Keychain、不绕登录或地区限制，不输出签名地址和凭据。
不自行安装覆盖或重启 /Applications 已安装应用，不清用户数据。可以构建独立测试 App，并用独立数据根验证；不使用 AppleScript/辅助功能。
未批准直接写生产数据。真实生成服务只复用既有获授权入口，发现需要额外付费或凭据授权时具体报告。

## DSH 需要完成

- 先核对当前实现与回退记录，恢复最小原生链接链路，避免重复/冲突写入。
- 补齐 helper 内置打包、hash 校验及许可证、当前可用的 JS runtime 配置（如需要），不得以空 hash 的 fail-closed 状态交付。
- 链接来源和屏幕标定通过世界 authority 持久化，签名媒体地址不得落盘；停/删/换片不得复活旧任务。
- 排查 YouTube 403/B 站412与黑屏，区分配置/请求/编码/平台阻断，不未经诊断统称反爬。Twitch真实播放验收。
- 角色动作查 root motion/坐标/骨骼映射/接触地面，修复并提供可重复测试和实际画面证据。
- 更新验收脚本和文档，逐项给出命令、退出码、证据路径及未通过原因。测试生成夹具须明确标注，不能冒充真实供应商。
- 在自身环境能做的构建/测试先做；主代理会在宿主独立运行最终构建和验收。沙箱阻断必须提供完整可运行命令，不标为完成。

只有当前 App 构建与运行、关键完整流程和已知缺陷验证都完成，才可声明交付验收通过。
