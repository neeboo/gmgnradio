# 跨平台客户端：独立工程起点

## 范围与来源

- 独立 worktree：`/Users/ghostcorn/.codex/worktrees/gmgn-cross-platform/gmgnradio`。
- 分支：`codex/cross-platform-bevy`。
- 起点：`0341b5887b90170f8d76fbc8ffb7eb0a67accbb8`，未复制主工作区未提交修改或环境凭据。
- 客户端：`apps/cross-platform/`，独立 Cargo workspace 与锁文件。现有 macOS 应用、服务和根锁不迁移、不覆盖。
- 当前目标是可运行和可测的迁移验证基线，不是完整替代客户端。

## 决策边界

| 责任 | 当前方向 | 当前不声称具备 |
|---|---|---|
| 空间客户端 | Bevy/wgpu，Mac Metal / Windows DX12等后端，复用同一场景与输入逻辑 | 现有Swift/Metal代码可以原样搬入 |
| 世界权威 | 保留taskd现有状态、revision、事实流协议，客户端消费投影 | Bevy ECS成为第二个可持久化权威 |
| 产品UI | 先用Bevy最小控件验证输入和焦点；聊天/收件箱/音乐UI架构单独验证 | 已选定WebView叠加或完成中文输入/无障碍验收 |
| 媒体 | 网站链接优先，继续采用内置yt-dlp；播放会话统一，渲染适配独立 | fixture电视或贴图等同真实网站播放 |
| 音乐 | 队列/进度/会话与UI、场景音箱分离；个人立体声与空间音频明确区分 | Bevy音效支持就等于完整音乐播放器 |
| 平台能力 | 窗口、IPC、权限、安装、签名、更新分别适配 | Rust代码自动在Windows可运行 |

## 第一版验证

- 窗口、3D房间与相机；占位实体明确为fixture，不伪装生产资产或真实角色验收。
- 无GPU headless smoke验证基本ECS行为，不能代替画面验收。
- 性能运行记录实际backend和帧耗时分布，长帧单列；不只看平均FPS。
- macOS本地执行。Windows CI定义编译、测试和headless smoke；未推送/未执行前记为待验证。
- 单独固定Rust版本，不修改机器默认工具链。Bevy 0.19.1的官方最低Rust版本为1.95。

## 迁移门槛

1. 导入真实房间和现有角色，验证glTF/VRM、材质、骨架、动作重定向、脚底和手持挂点；原生客户端保留可对照基线。
2. 接真实taskd投影，检验摆放/删除/恢复和revision冲突，不复制第二份持久状态。
3. 网站链接 -> yt-dlp -> 音视频解码 -> 场景纹理，验证实际声音、深度遮挡、停止释放和长帧。
4. 聊天/收件箱/音乐队列、中文输入、焦点仲裁与重启恢复，明确原生或Web UI的合成方案后再迁移。
5. 同一场景、资产、分辨率、镜头路径与媒体对照Metal原版和Bevy；记录CPU/GPU、内存及帧时间。
6. Windows实机验证与安装/更新打包，CI通过不代替GPU、声音或产品验收。

## 已知平台阻碍

`services/gmgn-taskd/src/main.rs`目前使用`tokio::net::UnixListener`，持久根锁等实现也有平台依赖。后续需保持协议语义，增加Windows IPC/锁适配（如named pipe），不得声称现有服务已经跨平台。Windows客户端构建不需要编译这两个旧服务。

## 验证记录

构建、测试与实际渲染结果在完成后追加；此处不预填成功。

官方版本依据：https://github.com/bevyengine/bevy/blob/v0.19.1/Cargo.toml
# 决策更新（2026-10-03）

用户决定暂不替换跨平台引擎，优先建设可恢复的世界备份。此独立原型保留为对照，不继续扩展客户端、迁移引擎或增加平台实施。后续引擎替换需消费版本化世界语义及原始资产归档，不依赖此原型缓存。
