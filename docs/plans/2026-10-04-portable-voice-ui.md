# 跨平台语音与界面迁移

## 已确认范围

先下沉 TTS/ASR 与标准化 Rust MCP/客户端协议，再迁移 GPUI Kit 界面。现有 SceneKit、Metal 空间、人物和 3D 音乐播放器不替换。当前交互是按住说话、松开提交，回答正常播放；音频上传与输出保持流式，不做双向实时通话、不新增 LiveKit。供应商涵盖百炼、ElevenLabs、Fish Audio；能力以各家的实际接口为准。

## 实现状态（真实ASR验收按用户要求暂停）

- `gmgn-protocol`：共享帧上限、请求ID、回复/事件判据和私有端点格式。保持现有业务 wire 字段和 MCP 工具权限。
- taskd 与 MCP 通信改为仅绑定127.0.0.1随机端口的TCP，每条请求鉴权；token只在私有端点文件及内存中使用，不进入日志或能力合同。默认 `taskd.endpoint.json`，启动支持 `--endpoint-file`，旧 `--socket` 参数保留为路径参数别名，旧socket文件不删除、不覆盖。
- 单写入继续使用 fs2 锁；Unix权限作为条件实现，Windows使用当前用户SID私有DACL、重解析点拒绝与原子文件替换。Windows文件模块和条件测试跨目标编译通过，完整Windows构建仍缺C SDK，未做Windows运行验收。
- Swift世界、生成和语音客户端及独立host-tools桥接均已切私有回环TCP。SceneKit和设备录放音仍是平台宿主实现；这不等于整个应用已经完成跨平台迁移。
- `gmgn-voice-core`：百炼真实WebSocket流式TTS协议；ElevenLabs/Fish Audio HTTP流式TTS。首个音频块即可交付，有界队列、generation与取消隔离，均不等待完整音频下载。输出为PCM16单声道24kHz，播放设备和嘴型仍由宿主接入。
- 百炼/ElevenLabs ASR socket transport、手动commit、转写去重、taskd服务和App按住说话流程已集成；完整非空语句→Agent回复→播放的真实ASR验收尚未完成，并已按用户要求暂停。
- Fish官方 `/v1/asr` 为音频文件上传，当前没有确认的公开流式ASR接口，未虚构这项能力。

## 实际验证与失败记录

Rust workspace测试包括MCP 13单元/7 stdio/4隔离，共享协议3、taskd135、voice-core16项，总计178项通过；本地HTTP/WS测试覆盖首块早于响应结束、取消与重定向凭据隔离。这些测试不算真实供应商或真实App验收。主代理最终日志 `/tmp/gmgn-portable-voice-workspace-final2.log` exit0。

`/tmp/gmgn-portable-voice-workspace-tests.log` 首轮失败：严格私有文件检查拒绝macOS临时路径祖先别名，以及错误码表未同步。测试临时目录改为规范化系统临时根，鉴权码纳入唯一合同，第二轮 `/tmp/gmgn-portable-voice-workspace-tests2.log` 全部通过。最终复验日志 `/tmp/gmgn-portable-voice-workspace-final.log`。

主代理Swift生成客户端检查28项通过。真实taskd单写入探针首次因 `/tmp` 别名拒绝启动（exit5），日志 `/tmp/gmgn-parent-portable-world-tests.log`；Foundation规范化仍会缩回 `/var`，第二次日志 `/tmp/gmgn-parent-portable-world-tests2.log` 仍失败。macOS测试夹具最终使用POSIX realpath，实际复验 `/tmp/gmgn-private-fixture-world-check.log` exit0、failures=0/warnings=0，私有文件安全规则未放宽。不掩盖首次失败。

没有启动或替换已安装App、没有读Keychain、没有输出凭据或清用户数据。独立宿主构建和真实ElevenLabs TTS播放/取消已验收，真实非空ASR完整链路尚未验收。GPUI尚未迁移。

## GPUI与3D边界调研

GPUI Kit的paint/canvas是UI绘制接口，不提供SceneKit等价的完整场景图、物理和角色动画引擎。GPUI上游已有 `surface(CVPixelBuffer)`，但当前该入口限定macOS/iOS，不能直接当成统一跨平台3D纹理接口。现有工程已使用SCNRenderer与Metal组合，迁UI应继续让原引擎渲染，再解决共享画面、GPU同步、焦点和输入，不重写人物与播放器。

没有做同场景性能对比，无法断言GPUI合成会更快或更慢。验收门禁应包含真实3840×2160场景、持续缩放、人物动作、电视画面声音、UI叠加和输入焦点，避免GPU→CPU逐帧读回。

- [GPUI Kit Paint](https://gpui-kit.com/docs/paint/)
- [GPUI上游surface源码](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/elements/surface.rs)
- [SceneKit场景节点](https://developer.apple.com/documentation/scenekit/scnnode)
- [百炼ASR手动提交](https://help.aliyun.com/en/model-studio/qwen-asr-realtime-client-events)
- 供应商具体协议与验证范围见 `services/gmgn-voice-core/PROVIDERS.md`。

## 后续顺序

### 2026-10-04 当前整合断点（未完成验收）

Rust 已加入百炼/ElevenLabs 手动提交 ASR WebSocket transport，taskd 增加按连接隔离的流式语音 RPC。App 默认 TTS/ASR 已接 Rust，宿主仅负责麦克风 PCM 与设备播放；设置及 Stage/LiveCam 的按住/松开入口已接入。旧进程测试迁移到 TCP，业务19项、记忆5项、鉴权与 token 轮换1项通过。

主代理全工作区测试 `/tmp/gmgn-rust-voice-integrated-tests3.log` 通过；前两次错误码排序测试失败已修正。宿主第一次构建因 LiveCam 松开回调缺失失败，第二次 `/tmp/gmgn-rust-core-app-build2.log` BUILD SUCCEEDED。

实际隔离 App 根 `/private/tmp/gmgn-rust-voice-real-20261004`：启动及语音配置状态读回成功，使用内存 ElevenLabs 配置，无 Keychain 读取。真实 TTS 开始后 App 崩溃，不能算通过。崩溃证据 `gmgn radio-2026-10-04-003401.ips`：音频 tap 回调错误继承 MainActor，触发 Swift executor/dispatch 队列断言；已交回播放适配器修复，随后必须重建并复验真实声音与 ASR。

剩余独立 host-tools 的 Unix 传输正在迁移，Windows 实机运行门禁仍未通过；GPUI 尚未开始迁移。

播放回调修复后，第三、四次宿主构建通过。隔离根 `/private/tmp/gmgn-rust-voice-real2-20261004` 的实际 ElevenLabs → Rust → App TTS 完整播放结束且无错误；按 PID68560 输出采样 `evidence/tts-audible.json` exit0，rms=0.05169、peak=0.48251、globalTap=false、scopedProcesses仅该PID。ASR 开始采集后仅送3050字节即失败，完整语音链仍未通过。独立安全连接检查收到 ElevenLabs `session_started`，并发送同长度 PCM 后4秒内无服务错误；正在修复 App 与云端握手就绪时序，不能将该检查算 App ASR 验收。

ASR ready 门禁完成后，第五、六次构建通过，主代理 Rust 全工作区 `/tmp/gmgn-rust-voice-ready-workspace3.log` exit0，共186项。真实 App `/private/tmp/gmgn-rust-voice-speaker-20261004` 采集263486字节并手动提交，收到空final且没有误送Agent；capturedPeak=0、lastFinalReceived=true、emptyFinalCount=1。设备诊断确认 AppleClamshellState=Yes、默认内置麦克风。Apple 官方说明合盖时会硬件断开内置麦克风：[说明](https://support.apple.com/guide/security/secbbd20b00b/web)。仅隔离App的语音engine选择扬声器，没有修改系统默认设备；原始麦克风音频未保存。

用户随后明确要求“先不测ASR，等我起床再测”：ASR全部测试与录音暂停，不再请求麦克风或云端ASR；保留未完成门禁，等用户恢复后继续。继续TTS、接口取消安全修复与真实业务回归，不把硬件阻断计为通过。

非ASR业务实跑：新根 `/private/tmp/gmgn-rust-core-business-20261004` 首次137通过/2失败/1阻断，真实生成、入库、摆放、动作、通知已读及聊天通过；失败是直接HLS地址不在当前视频来源策略内，未放宽策略。换已支持的Twitch链接、复用已生成任务后149通过/1失败/1阻断，原生电视画面、按PID声音及恢复通过；该次复用任务没有新未读通知，通知翻转门禁具名失败，不能把复用流程冒充全新完整通过。日志分别 `/tmp/gmgn-rust-core-business-e2e2.log`、`/tmp/gmgn-rust-core-business-twitch-retry.log`。

Host-tools两通道已迁私有回环TCP，89项宿主通道/172项Node MCP桥接检查通过。审阅发现取消时直接abort生产者可能截断NDJSON，已改每连接8帧专属writer完成整帧，并限制in-flight请求队列；非ASR慢读取消、超限、64请求顺序等检查通过。

最终构建 `/tmp/gmgn-rust-core-final-app-build.log` BUILD SUCCEEDED；ASR暂停后仅运行非ASR任务服务138项和MCP/协议27项，全部通过。新端点读取负对照7项、设备PCM/TTS20项通过，安全复审未发现新的具体阻断问题。端点读取的no-follow保护最后分量，仍依赖taskd私有目录边界。

最终产物真实TTS-only `/private/tmp/gmgn-rust-tts-final-20261004/voice-report.json`：有声、drain结束、取消后无声均通过。PID80979的输出采样 rms=0.048738/peak=0.422445，取消后 rms=0/peak=0；globalTap=false且scopedProcesses仅该PID。驱动器整体exit2、status=partial、pending=asr_paused_by_user，明确不将TTS通过升级为完整语音通过。该次没有录音或ASR请求。

最终产物全新真实业务回归 `/private/tmp/gmgn-rust-core-final-business-20261004/evidence/summary.json`：160通过、0失败、0阻断，进程exit0。日志 `/tmp/gmgn-rust-core-final-business-e2e.log`。真实生成任务 `1578662C-4F47-4ABB-B70E-8724746823C4` 完成生成、世界入库、摆放手持、人物动作、Twitch原生电视画面与声音、通知已读、重启恢复和真实聊天；隔离检查确认没有写真实用户Application Support。本轮不包含ASR，完整Rust语音链仍待用户恢复后验收。

1. 完成Rust ASR transport与语音服务接口，接回Swift录放音桥接并验收真实按住说话流程。
2. 将剩余宿主能力逐项纳入有版本、可发现、统一错误和事件的接口，保留权威与平台实现的边界。
3. 实际验证GPUI Kit承载现有场景；桥接与体验达标后迁移聊天、资产、设置及其它界面，不替换引擎。

## 2026-10-04 三供应商TTS与声音选择补验

用户要求补测全部TTS供应商并实现界面声音选择；ASR暂停指令继续有效。本轮仅检查相关环境变量与App偏好是否配置，不输出凭据、不读Keychain。ElevenLabs环境密钥和百炼既有偏好可用；Fish环境变量与App偏好未找到Key，真实App配置检查 `/private/tmp/gmgn-tts-fish-config-check-20261004/voice-report.json` 为blocked/missing_voice_configuration，未调用Fish云端。

已有产物的真实App百炼链路 `/private/tmp/gmgn-tts-bailian-real-20261004/voice-report.json` 通过有声、结束、取消无声；输出仅PID87623，rms=0.050518/peak=0.382777。ElevenLabs复测 `/private/tmp/gmgn-tts-eleven-repeat-20261004/voice-report.json` 同样三项通过。两个报告整体status=partial仅表示ASR仍暂停，不代表TTS失败。声音列表与选择UI的新产物验收另行记录。

声音选择已实现：Swift通过鉴权 `voice_list` RPC查询Rust目录；百炼返回当前实现支持的4个TTS声音，ElevenLabs官方 `/v2/voices` 和Fish官方 `/model` 最多100项。只返回ID/名称，1MiB/20秒上限、禁重定向，不保存远端错误正文或凭据。界面支持名称选择、刷新、保存、试听/停止及高级自定义ID；不自动选首项，不把目录存在等同于当前账户可播放。`voice_capabilities`公开目录能力及上限。

真实界面初验失败：CUA按文件路径额外启动了不带隔离环境的测试实例，后续已关闭；没有安装或重启已装App。改按 `ai.gmgn.radio.e2e` 绑定并核对实际PID后复验。设置列表及试听客户端同时补上显式隔离根，与生产App注入路径一致。不能依据早先界面失败推断供应商不可用。保存空密钥会遮住环境配置的问题已修复，8项生产配置测试证明空值继续环境/旧配置回退且环境Key不写偏好。

构建3的实际隔离App PID90363、根 `/private/tmp/gmgn-tts-selector-ui3-20261004`：CUA确认百炼4声音、ElevenLabs28声音，选择Serena、试听、保存；百炼界面试听采样rms=0.017080/peak=0.196240。ElevenLabs首个自建声音试听曾显示失败，未判为通过；Roger保存后试听复验rms=0.026410/peak=0.577086、无错误且正常结束。一次10秒采样无声，延长到覆盖播放的25秒窗口后通过，首次失败保留在证据目录。所有采样globalTap=false且仅该PID。Fish界面缺Key提示与禁用未选声音试听已核对，没有云端Fish验收。最终构建与重启恢复结果待补。

非ASR验证：taskd138项、目录3项、契约7项、Swift目录与端点13项、PCM/TTS20项、配置8项，以及设置隔离根/试听接线/错误清理/显式选择负例通过。没有运行ASR、录音或麦克风请求。

最终构建4 `/tmp/gmgn-tts-selector-build4.log` BUILD SUCCEEDED，helper清单校验通过。重启同一隔离根，PID93007，CUA确认已保存的ElevenLabs/Roger名称恢复、SecureField未显示环境密钥；生产AgentSpeech默认读取保存配置，无provider/voiceID环境覆盖。`evidence/final-ui-tts-report.json` 为ttsStatus=passed：真实有声、drain无错误、取消后PID输出无声全部通过。仅ASR仍暂停。界面不再自动选择目录首项，切服务清空旧试听错误。

最终产物百炼Serena中文复验 `/private/tmp/gmgn-tts-bailian-selector-final-20261004/voice-report.json` 为ttsStatus=passed：有声、正常结束、取消无声三项通过；整体partial/exit2仍仅指ASR暂停。ElevenLabs重启后输出rms=0.061152/peak=0.474559，取消后rms=0/peak=0，globalTap=false且仅PID93007。Fish尚缺Key，保持未验收。

### Fish Key补充后的真实复验

用户随后提供Key并明确要求保存到 `.zshrc`，已设置 `GMGN_VOICE_FISH_API_KEY`，仅本人读写；密钥不进入仓库、报告或日志。使用该配置启动实际隔离测试App，经生产Rust `voice_list` 成功返回100个声音，证据 `/private/tmp/gmgn-fish-catalog-real-20261004/evidence/catalog-report.json`。真实App Swift→Rust Fish TTS尝试未采到声音，报告 `/private/tmp/gmgn-fish-tts-real-20261004/voice-report.json` 保留failed，不能算通过。

诊断确认同一合成接口返回HTTP402，响应同时包含insufficient/balance/credits，安全分类证据 `evidence/provider-status.json` 只记录状态码和布尔判据，不存远端正文或凭据。因此当前阻断为供应商账户余额/额度不足；Key可查询声音目录，但真实TTS有声、结束及取消链路仍待额度恢复后复验。不操作充值，不将目录成功当作播放成功；本轮没有ASR或麦克风请求。

用户指出免费模型后更正验收范围：上述402是代码默认付费模型 `s2-pro` 的结果，不能推广到Fish全部模型。[官方TTS接口](https://docs.fish.audio/api-reference/endpoint/openapi-v1/text-to-speech) 明确支持请求头 `model: s2.1-pro-free`。本次通过内存环境 `GMGN_VOICE_FISH_TTS_MODEL=s2.1-pro-free` 覆盖进行真实App复验，未修改产品默认模型。`/private/tmp/gmgn-fish-free-tts-real-20261004/voice-report.json` 为ttsStatus=passed，有声、drain结束及取消后无声全部通过；仅PID5744输出rms=0.020403/peak=0.175827，globalTap=false。整体partial/exit2仅表示ASR仍暂停。免费模型无余额阻断，Fish真实TTS链已通过；之前付费失败证据保留。

## Unity + GPUI讨论范围

目前只是候选调研，没有授权启动引擎替换。Unity官方Unity as a Library支持列表包含Android/iOS/Windows/UWP，不包含macOS/Linux；因此不能把Unity嵌入GPUI单窗口视为已有统一跨平台方案。独立窗口+Rust服务通信可以先验证业务分工；同窗口GPU共享需要另做平台桥接原型。当前继续保持SceneKit/Metal不变。

- [Unity官方库嵌入支持与限制](https://docs.unity.com/en-us/engine/6000.3/manual/platform-specific/cross-platform-features/unityasa-library)
