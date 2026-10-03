# 跨平台语音与界面迁移

## 已确认范围

先下沉 TTS/ASR 与标准化 Rust MCP/客户端协议，再迁移 GPUI Kit 界面。现有 SceneKit、Metal 空间、人物和 3D 音乐播放器不替换。当前交互是按住说话、松开提交，回答正常播放；音频上传与输出保持流式，不做双向实时通话、不新增 LiveKit。供应商涵盖百炼、ElevenLabs、Fish Audio；能力以各家的实际接口为准。

## 第一批已实现，尚未完成 App 接入

- `gmgn-protocol`：共享帧上限、请求ID、回复/事件判据和私有端点格式。保持现有业务 wire 字段和 MCP 工具权限。
- taskd 与 MCP 通信改为仅绑定127.0.0.1随机端口的TCP，每条请求鉴权；token只在私有端点文件及内存中使用，不进入日志或能力合同。默认 `taskd.endpoint.json`，启动支持 `--endpoint-file`，旧 `--socket` 参数保留为路径参数别名，旧socket文件不删除、不覆盖。
- 单写入继续使用 fs2 锁；Unix权限作为条件实现，Windows使用当前用户SID私有DACL、重解析点拒绝与原子文件替换。Windows文件模块和条件测试跨目标编译通过，完整Windows构建仍缺C SDK，未做Windows运行验收。
- Swift世界与生成客户端已切回环TCP，未改其他独立host-tools桥接；因此整个应用仍有尚未迁移的Unix宿主接口，不能宣称整个应用已跨平台。
- `gmgn-voice-core`：百炼真实WebSocket流式TTS协议；ElevenLabs/Fish Audio HTTP流式TTS。首个音频块即可交付，有界队列、generation与取消隔离，均不等待完整音频下载。输出为PCM16单声道24kHz，播放设备和嘴型仍由宿主接入。
- 百炼ASR已移植手动commit协议与转写去重；ElevenLabs已移植Scribe手动commit消息。ASR socket transport、App按住说话流程、Rust服务暴露与真正播放集成仍待做。
- Fish官方 `/v1/asr` 为音频文件上传，当前没有确认的公开流式ASR接口，未虚构这项能力。

## 实际验证与失败记录

Rust workspace测试包括MCP 13单元/7 stdio/4隔离，共享协议3、taskd135、voice-core16项，总计178项通过；本地HTTP/WS测试覆盖首块早于响应结束、取消与重定向凭据隔离。这些测试不算真实供应商或真实App验收。主代理最终日志 `/tmp/gmgn-portable-voice-workspace-final2.log` exit0。

`/tmp/gmgn-portable-voice-workspace-tests.log` 首轮失败：严格私有文件检查拒绝macOS临时路径祖先别名，以及错误码表未同步。测试临时目录改为规范化系统临时根，鉴权码纳入唯一合同，第二轮 `/tmp/gmgn-portable-voice-workspace-tests2.log` 全部通过。最终复验日志 `/tmp/gmgn-portable-voice-workspace-final.log`。

主代理Swift生成客户端检查28项通过。真实taskd单写入探针首次因 `/tmp` 别名拒绝启动（exit5），日志 `/tmp/gmgn-parent-portable-world-tests.log`；Foundation规范化仍会缩回 `/var`，第二次日志 `/tmp/gmgn-parent-portable-world-tests2.log` 仍失败。macOS测试夹具最终使用POSIX realpath，实际复验 `/tmp/gmgn-private-fixture-world-check.log` exit0、failures=0/warnings=0，私有文件安全规则未放宽。不掩盖首次失败。

没有启动或替换已安装App、没有读Keychain或凭据、没有清用户数据。全套宿主构建、真实ASR录音、真实供应商首音频与播放、打断取消、人物嘴型与恢复流程尚未验收。GPUI尚未迁移。

## GPUI与3D边界调研

GPUI Kit的paint/canvas是UI绘制接口，不提供SceneKit等价的完整场景图、物理和角色动画引擎。GPUI上游已有 `surface(CVPixelBuffer)`，但当前该入口限定macOS/iOS，不能直接当成统一跨平台3D纹理接口。现有工程已使用SCNRenderer与Metal组合，迁UI应继续让原引擎渲染，再解决共享画面、GPU同步、焦点和输入，不重写人物与播放器。

没有做同场景性能对比，无法断言GPUI合成会更快或更慢。验收门禁应包含真实3840×2160场景、持续缩放、人物动作、电视画面声音、UI叠加和输入焦点，避免GPU→CPU逐帧读回。

- [GPUI Kit Paint](https://gpui-kit.com/docs/paint/)
- [GPUI上游surface源码](https://github.com/zed-industries/zed/blob/main/crates/gpui/src/elements/surface.rs)
- [SceneKit场景节点](https://developer.apple.com/documentation/scenekit/scnnode)
- [百炼ASR手动提交](https://help.aliyun.com/en/model-studio/qwen-asr-realtime-client-events)
- 供应商具体协议与验证范围见 `services/gmgn-voice-core/PROVIDERS.md`。

## 后续顺序

1. 完成Rust ASR transport与语音服务接口，接回Swift录放音桥接并验收真实按住说话流程。
2. 将剩余宿主能力逐项纳入有版本、可发现、统一错误和事件的接口，保留权威与平台实现的边界。
3. 实际验证GPUI Kit承载现有场景；桥接与体验达标后迁移聊天、资产、设置及其它界面，不替换引擎。

## Unity + GPUI讨论范围

目前只是候选调研，没有授权启动引擎替换。Unity官方Unity as a Library支持列表包含Android/iOS/Windows/UWP，不包含macOS/Linux；因此不能把Unity嵌入GPUI单窗口视为已有统一跨平台方案。独立窗口+Rust服务通信可以先验证业务分工；同窗口GPU共享需要另做平台桥接原型。当前继续保持SceneKit/Metal不变。

- [Unity官方库嵌入支持与限制](https://docs.unity.com/en-us/engine/6000.3/manual/platform-specific/cross-platform-features/unityasa-library)
