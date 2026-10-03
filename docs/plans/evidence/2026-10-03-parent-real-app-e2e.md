# 主代理真实 App 端到端验收（未通过）

## 当前实测

- 独立测试 App：`tmp/e2e-app-build/DerivedData/Build/Products/Release/gmgn radio.app`，bundle id ai.gmgn.radio.e2e。
- 当前成功构建日志：`/tmp/gmgn-parent-host-e2e-auth-build-20261003.log`，exit 0；随后 DSH 修改需重新构建。
- taskd、MCP、yt-dlp 内置与哈希校验已通过。
- 长根目录启动失败；短根目录启动成功。原始日志分别 `/tmp/gmgn-parent-real-app-e2e-20261003.log` 和 `/tmp/gmgn-parent-real-app-shortroot2-20261003.log`。
- 标准 PMX 人物、BONES idle/walk/chair-sit/jumping-jacks 包以复制方式纳入短测试根，未符号链接到生产。原始选择与资产未改。
- 完整驱动最近运行：`/tmp/gmgn-e2e-20261003-1710`，日志 `/tmp/gmgn-parent-real-app-assets-20261003.log`，exit 1。29 pass / 2 fail / 1 blocked，不构成交付通过。
- 实际窗口观察已确认人物显示；真实 GPU 回读5帧，5个不同摘要，帧序号递增、跨度1.666秒。当前只验idle，不能宣称运动穿地已验。
- 真实生成服务产出 GLB 4,950,064 bytes；未使用回环生成夹具。

## 剩余真实失败

1. claim_wish_output：物品还未完成下载检查，暂时不能领取。库存为空，摆放面为空，未完成摆放与手持。
2. play_screen 内层 screen_not_found。旧驱动误把邮箱外层ok=true算播放接受，主代理已修正传播内层工具失败。没有实际电视画面/声音通过证据。
3. 通知标已读后未读数下降、重复操作幂等；重启找不到已读通知记录，虽然未读数0，仍拒收。
4. 当前走正式生成工具链，尚未完成聊天agent用户提交回合；动作需要实际触发并连续验。

## 持续跟进

- DSH 安全资产与活动修复进行中，日志 `/tmp/gmgn-dsh-safe-assets-activity-fixes-20261003.log`，exec session 90774。
- 已排队在其结束后继续修领取/入库/重启失败，日志 `/tmp/gmgn-dsh-claim-restart-fixes-20261003.log`。同一生产区域串行写，避免两个 DSH 并发修改。
- 线程自动跟进 automation id gmgnradio，10分钟间隔；无变化安静，实际失败/进展才通知。主代理不得等待用户催问才复验。
- 验收未通过；继续当前引擎，不覆盖安装App、不操作用户真实状态或Keychain。
# 18:35 HLS停滞修复后的真实恢复复验

1833当前宿主构建exit0，`/tmp/gmgn-parent-reacceptance-1833-real-app.log` exit1，102pass/1fail/2blocked。HLS视频解码11→74、时钟+2.089s、GPUdraw177/quads177/fragments736497，后续实时443帧/rate1/noError。三类动作姿态/接地、摆放手持放回、重启接地和真实chat delivered通过；HLS声音采样不支持仍阻断，旧通知全已读不能重验新状态翻转。未完成全新生成端到端验收。

# 18:14 真实 App 对话专项复验

当前宿主1813构建exit0，真实App chat专项exit0，7pass0fail0blocked，日志 `/tmp/gmgn-parent-reacceptance-1813-chat.log`。真实输入→可见历史→sendEnteredCount→modelTurnsStarted→delivered终态通过。未将此计为整体验收；此前failed未复现，新增安全失败诊断保留。DSH当前继续音频停滞返工。

# 18:10 最新真实 App 音频返工复验

1803/1806宿主构建均exit0。1803真实App播放阶段崩溃，ips为`gmgn radio-2026-10-03-180453.ips`，音频实时线程触发MainActor隔离断言；主代理修install回调隔离。随后修崩溃遗留邮箱quit重放，旧JSON保存在测试evidence/stale-mailbox。

`/tmp/gmgn-parent-reacceptance-1806-real-app2.log` exit1，83pass/2fail/1blocked。三类真实动作姿态、clip+epoch时钟、接地、摆放手持放回和重启接地通过。新tap版实际播放decodedFrames1/rate0/time16，tapAttachedtrue/all-tracks/buffers22/frames98428/peak0，视频停滞、声音缺证，拒收。chat本轮显式跳过，旧已读任务无法产生新未读状态翻转；不当作完整验收。DSH chat安全诊断session6795正在推进，音频实际停滞返工已串行排队session25374。

# 17:56 最新真实 App 验收

当前树宿主构建1753 exit 0；真实恢复流程 exit 1，93 pass / 3 fail / 3 blocked。日志 `/tmp/gmgn-parent-reacceptance-1753-real-app.log`，最终 ledger `tmp/e2e-real-app/ledger.json`。电视解码帧1→48/time+1.704s，真实场景draw119/quads119/fragments398888；正式摆放、手持放回、行走跳跃真实骨骼姿态与重启接地通过。坐下时钟跨重置、音频tap未挂上、真实chat终态failed仍拒收。旧已读任务恢复未产生新未读通知，不能算通知翻转本轮通过。DSH实际返工session24957，日志 `/tmp/gmgn-dsh-audio-chat-clock-1756.log`，原进程2199已停止且改动全保留。

# 17:38 主代理当前构建与真实恢复流程

- 当前完整宿主构建 exit 0：`/tmp/gmgn-parent-reacceptance-1740-build2.log`。主代理修两个 Swift 控制入口类型错误。
- 同一隔离根真实 App 恢复运行 exit 1：`/tmp/gmgn-parent-reacceptance-1740-real-app3.log`，53 pass / 6 fail / 0 blocked。此轮复用已生成任务，不计为新生成或聊天回合通过。
- 已实测：托盘可领取、居民走到取物点、领取入库、3136承托层、正式手持放回、已读和重启恢复、生产数据指纹未变化。
- 未过：摆放碰撞拒绝、screen_not_found、重启接地断言。两条动画版本失败由误用资源版本造成，但真实骨骼运动仍需采样。声音、坐下、完整聊天和重启物件屏幕恢复仍未完成。
- DSH 已依据本轮实际 ledger 继续修，session 70470，日志 `/tmp/gmgn-dsh-real-failures-1738.log`；旧 DSH 84620 已停止，保留全部已有改动。
