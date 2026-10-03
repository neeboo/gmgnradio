# 网站链接优先的场景播放器调研

日期：2026-10-03。目标：用户粘贴网站链接后在世界电视中播放；本地视频/HLS 输入优先级第二。本文区分官方资料、代码检查与实测，未把候选组件接入产品。

## 结论

不用 yt-dlp 技术上可行，但没有在本次核对的组件中找到可直接替换、完整覆盖 YouTube 点播 + B站点播 + Twitch 的单一方案。换播放器不会自动补齐网站解析。最值得做独立验证的是 YouTube.js；不能声称它已实测可靠。

网站页面链接 -> 站点解析 -> 可播放资源/请求头/音视频轨 -> 解码 -> 场景纹理，是四个独立责任。用户侧可保持只粘贴链接，内部仍要管理解析器依赖和更新。

## 核实结果

| 组件 | 网站解析能力与限制 | macOS 产品接入判断 |
|---|---|---|
| libmpv | mpv 的 ytdl_hook 默认寻找 yt-dlp/youtube-dl；禁用后无法据此获得 YouTube 网站解析 | 开源播放器候选，不满足独立免解析器目标。默认 GPL，存在 LGPL 构建选项，最终依赖构建也要核对 |
| libVLC | 有历史 Lua 网站解析；当前 VLC master 的 ytdl 模块默认执行 yt-dlp。3.x 有移除失效 youtube.lua 的维护讨论 | 不能作为可靠的免 yt-dlp 网站方案；libVLC 为 LGPL，仍须按打包的模块核对 |
| AVPro | Unity 视频播放插件，不是通用网站解析器 | 当前 Swift/Metal 项目无需为此引入 Unity；VRChat 使用它不能说明它自带链接解析 |
| YouTube.js | 独立 InnerTube 客户端，MIT，JS/TS，支持 Node/Deno/浏览器；URL 解签需提供 JS 执行器 | 不依赖 yt-dlp 的 YouTube 重点候选；内部 API、token、URL 过期、音视频分轨仍需处理。没有现成 Swift 官方适配，JavaScriptCore 移植可行性待验证 |
| NewPipeExtractor | Java 解析库，GPL-3.0-or-later；YouTube/SoundCloud/PeerTube/Bandcamp/media.ccc.de；无B站/Twitch | JVM/Rhino 与许可审查增加接入成本，不优先 |
| Streamlink | Python/BSD；Twitch live/vod，YouTube 仅直播不支持点播，B站仅 live.bilibili.com；Twitch 某些请求需要 Chromium 获取 CI token | 直播候选，不能替代三个网站的通用解析，也不能承诺完全无浏览器 |
| BBDown | 官方仓库已归档、不维护，当前默认分支只剩说明和许可证 | 不新增为交付依赖 |
| Nemo2011/bilibili-api | 官方仓库已归档，发布关停声明和平台告知函，当前主分支只剩说明 | 不能按历史资料推荐为持续维护的B站解析依赖；平台授权与合规需要单独评估 |
| ijkplayer | B站开源的 Android/iOS FFmpeg 播放器 | 播放内核，不等同于可解析B站网页/BV号的SDK，不是当前macOS的直接答案 |

## VRChat / Resonite 的实际做法

VRChat 官方帮助中心明确说明使用 yt-dlp 解析 YouTube、Twitch，并指出网站变化会造成临时不可用；内置版本有安全改动。世界里的播放器使用 AVPro/Unity，两者与解析器分工。

Resonite 官方 wiki 同样有 yt-dlp 更新说明及恢复视频播放的发布记录。因此“VR社交游戏能在世界播放网站链接”是真实先例，但不能推导出其没有解析组件或没有维护成本。

## 实测边界

- 本机未安装 mpv 或 VLC，未安装新的系统组件。因此本轮没有 libVLC/libmpv 真实网站播放成功证据。
- 本机 Streamlink 7.3.0 对 `https://www.twitch.tv/monstercat` 单次取流退出 1，报告 `No playable streams found`。未登录、未取浏览器 cookie；频道当时是否在线未另查，不能把该失败归因于组件不支持Twitch。
- `--can-handle-url` 只表示插件匹配，不能证明能获得流、解码、音画同步或场景渲染。
- 新增独立 AVFoundation/Metal 探针 `tools/probe-native-link-playback.swift`。已编译、参数拒绝与连接失败控制通过；尚无网站链接 -> 解析 -> 真实GPU帧成功证据。它不使用WebKit，不保存视频文件。
- 当前屏幕实现仅 `.officialEmbed`，世界播放器通过 WKWebView 覆盖层呈现；没有既存站点解析器。现有 AVPlayer 用于舞台视频，没有视频帧 -> Metal 纹理接线。

## 工程选择

1. 不先把 libVLC 当作万能链接播放方案接入，也不把 yt-dlp 固定为产品依赖。
2. 独立验证 YouTube.js：匿名公开点播链接、无浏览器登录导入，真实媒体读取与帧推进；同时测试失败、取消、URL过期和音视频分轨。网页信息解析成功不能当作播放成功。
3. Twitch 独立评估 Streamlink 的 token/浏览器条件；B站点播目前没有核实出的低维护统一替代，保留官方嵌入或获得授权接口。
4. 播放内核按流形态选择：AVPlayer + Metal适合Apple支持的单资源格式；分轨DASH等需求可能使libmpv/FFmpeg更合适。先确认解析结果，不提前选死。
5. 持久化原始网站链接，不保存带令牌的临时CDN URL；停止/换片/删除必须取消解析并撤销旧帧，禁止过期结果复活已删电视。

## 官方来源

- VRChat解析器：https://help.vrchat.com/hc/en-us/articles/1500002378742-I-m-having-issues-with-video-players-in-VRChat
- VRChat播放器：https://creators.vrchat.com/worlds/udon/video-players/
- Resonite：https://wiki.resonite.com/Updating_yt-dlp
- mpv解析接线：https://github.com/mpv-player/mpv/blob/master/player/lua/ytdl_hook.lua
- mpv许可证：https://github.com/mpv-player/mpv/blob/master/Copyright
- VLC解析模块：https://github.com/videolan/vlc/blob/master/modules/demux/ytdl.c
- VLC历史Lua维护：https://mailman.videolan.org/pipermail/vlc-devel/2026-January/143818.html
- libVLC：https://www.videolan.org/vlc/libvlc.html
- AVPro：https://renderheads.com/products/avpro-video/
- YouTube.js：https://github.com/LuanRT/YouTube.js
- YouTube.js执行器：https://ytjs.dev/guide/getting-started#providing-a-custom-javascript-interpreter
- NewPipeExtractor：https://github.com/TeamNewPipe/NewPipeExtractor
- Streamlink支持范围：https://streamlink.github.io/plugins.html
- Twitch条件：https://streamlink.github.io/cli/plugins/twitch.html#client-integrity-token
- BBDown：https://github.com/nilaoda/BBDown
- bilibili-api：https://github.com/Nemo2011/bilibili-api
- ijkplayer：https://github.com/Bilibili/ijkplayer

资料中的组件许可证不替代最终分发合规审查；开源许可也不等同于获得视频网站内容/接口授权。
