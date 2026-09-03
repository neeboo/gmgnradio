# gmgn radio MMD 角色与动作设计

## 目标

让空间舞台和桌面角色同时支持以下组合：

| 角色 | 自然待机 | VRMA | VMD |
|---|---:|---:|---:|
| VRM | 支持 | 原生播放 | 骨骼重定向 |
| PMX | 支持 | 暂不开放 | 原生播放 |

角色在空间模式中必须和 SPZ 共用 Metal 命令缓冲、相机矩阵和深度纹理。动作不改变空间锚点；DJ 口型、眨眼和注视始终覆盖在导入动作之上。

## 技术选择

### VMD 驱动 VRM

使用 nanoem 的 MIT 核心 C 库解析 VMD。只引入 `nanoem.c`、公开头文件和 macOS CFString 扩展，不引入 nanoem 的完整编辑器、Sokol 图形层、Bullet 或 protobuf。Swift 层把 nanoem 的骨骼、表情和插值关键帧转换为中立的 `VMDMotionDocument`，再由 `VMDToVRMClipAdapter` 转成 `VRMMetalKit.AnimationClip`。

### PMX + VMD

使用 MIT 许可的 MMDSceneKit 作为首版 PMX 渲染后端。它已经能在当前 Xcode 26.6 / Apple Silicon 环境构建，并支持 PMX、VMD、IK、变形与 SceneKit Metal 渲染。通过 `SCNRenderer.render(atTime:viewport:commandBuffer:passDescriptor:)` 编码到 Marble 的 drawable 和深度纹理，角色因此能进入同一个空间。

nanoem 的完整 Metal 应用层采用 MPL 2.0，并围绕 Sokol 全局图形状态设计，无法直接成为现有 `MTLCommandBuffer` 的独立渲染器，所以首版只复用其解析核心。后续若 MMDSceneKit 的物理或材质兼容不足，再把 nanoem emapp 的模型绘制层拆成独立编码器。

## 运行时合同

```swift
enum StageAvatarFormat: String, Codable, Sendable { case vrm, pmx }
enum StageMotionFormat: String, Codable, Sendable { case procedural, vrma, vmd }

struct StageAvatarAsset: Equatable, Sendable {
    let id: String
    let name: String
    let format: StageAvatarFormat
    let modelURL: URL
    let resourceRootURL: URL
}

struct StageMotionAsset: Equatable, Sendable {
    let id: String
    let name: String
    let format: StageMotionFormat
    let url: URL?
}
```

`StageAvatarRuntimeSnapshot` 同时携带角色和动作。模型选择、动作选择分别持久化，加载失败保留上一套可用组合。

渲染器统一实现 `StageAvatarRendering`：加载动作、按 DJ 状态更新时间、编码到指定 Metal pass。VRM 后端封装 `VRMRenderer`；PMX 后端封装 `SCNRenderer` 和 `MMDNode`。

## 动作采样顺序

1. 采样 VRMA 或 VMD。
2. 关闭根位移，把角色固定在 `StageAvatarPlacement`。
3. 叠加 DJ 的口型、眨眼和视线。
4. 执行 IK、弹簧骨或 MMD 物理。
5. 更新最终骨骼矩阵并编码 Metal draw call。

VMD 相机、灯光和阴影关键帧首版不接管 Marble 相机。VMD 的骨骼和表情保留原始贝塞尔插值。

## 资源与设置

模型与动作分开存放：

- `PresencePackages/`：呼吸球、VRM、PMX 及 PMX 纹理目录。
- `MotionPackages/`：内置自然待机、Studio Groove、用户导入 VRMA/VMD。

设置页沿用现有“桌宠”页面，标签缩短为“角色”，页面内分成“角色”和“动作”两区。顶部只有一个“导入”菜单，分别导入模型和动作。PMX 按目录或 ZIP 安装，必须验证纹理相对路径，任何越界路径都拒绝。

## 错误策略

- VMD/VRMA 文件头损坏：安装阶段拒绝。
- 动作与角色不兼容：保留在库中但禁用选择，并显示原因。
- 当前动作运行时加载失败：继续上一套动作，不清空角色。
- PMX 纹理缺失：列出缺失文件，不静默使用空白材质。
- PMX 渲染失败：空间中回退到当前 VRM 或呼吸球，错误进入设置页状态。

## 验证边界

自动验证只运行解析测试、纯模型测试、`build-for-testing`、资源哈希和签名无关的静态检查。不得启动 gmgn radio、Xcode 测试宿主、AppleScript、系统事件、钥匙串查询或临时签名。

