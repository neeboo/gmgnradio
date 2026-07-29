# 音乐服务接入结论

## 当前实现

- 网易云音乐：客户端直连搜索、账号歌单、红心歌单歌曲和播放地址接口。
- QQ 音乐：客户端直连搜索、账号歌单和 VKey 播放地址接口。
- Apple Music：使用系统 MusicKit 完成授权、订阅能力检查、目录搜索、队列和播放控制。
- 网易云与 QQ 音乐的 Cookie 只保存在 macOS 钥匙串，请求直接发往对应音乐服务。
- 每首歌是否能完整播放，仍由用户账号、会员、版权和地区权限决定。

实现参考了 Mineradio 已验证的产品路径，但没有复制其 GPL 代码。gmgn radio 使用自己的 Swift 请求、数据模型和测试。

## Apple Music 闸门结论

MusicKit 在当前 macOS SDK 上可以完成：

- `MusicAuthorization.request()` 授权；
- `MusicSubscription.current.canPlayCatalogContent` 订阅能力检查；
- `MusicCatalogSearchRequest` 搜索；
- `ApplicationMusicPlayer` 队列、播放、暂停和跳过。

当前限制：

- `ApplicationMusicPlayer.transition` 在 macOS 明确不可用，不能使用官方交叉淡化；
- MusicKit 没有公开 PCM、音频 Tap 或独立输出节点；
- Apple Music 音频不能进入 gmgn radio 的 `AVAudioEngine`，因此无法使用同一条链路做精确压低音乐和音频驱动 GFX。

因此 Apple Music 进入首版的搜索与系统播放路径；网易云、QQ 音乐以及本地文件继续走可控音频路径。Apple Music 的精确音画与混音保持关闭，不使用私有 API。

## 后续运行验证

- 使用真实网易云和 QQ 音乐账号验证普通歌曲、会员歌曲、无版权歌曲和过期 Cookie；
- 下载远程播放地址到短期缓存，再送入现有 `AVAudioEngine`；
- 测试地址过期、Range 请求、设备切换和睡眠恢复；
- 有 Apple Music 订阅账号后验证系统授权、后台播放和睡眠恢复。

## 来源

- Apple MusicKit：<https://developer.apple.com/documentation/musickit>
- Mineradio：<https://github.com/XxHuberrr/Mineradio>
