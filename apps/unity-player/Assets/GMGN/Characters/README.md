# PMX 角色运行时接入

此模块读取真实用户 PMX 与 VMD，不包含示例角色、替代模型或伪动作。尚需安装依赖、接到角色资源投影并完成 Release 视觉验收，不能作为角色迁移完成的证据。

## 依赖

- [UnityMMDTools](https://github.com/CandidumGames/UnityMMDTools)，MIT；已审阅版本 `0.5.1`，固定提交 `db35d9cb80ad57a8b2cbd40ad737a3c7bbe2d6c4`。
- 通过 Unity Package Manager 安装 `https://github.com/CandidumGames/UnityMMDTools.git#db35d9cb80ad57a8b2cbd40ad737a3c7bbe2d6c4`，再启用 `GMGN_UMT` 编译符号。不手动编辑 manifest。
- 保留该依赖及其第三方许可证。用户模型与动作的许可证不受 MIT 包许可证替代；不把用户角色资产提交或重新分发。

UMT 声明 Unity 2022.3+ / URP。其预编译 Bullet 插件仅支持 Windows、Android 和 Web；macOS 原生物理未验收。模块使用公开托管 PMX 构建器，跳过会初始化 Bullet 的 `MMDTransformBuilder`，并关闭 VMD 物理烘焙。

## 接入

在世界角色锚点的 GameObject 添加 `PmxCharacterRuntime`，依次 await：

```csharp
await runtime.LoadAsync(characterId, modelPath, heightMeters);
await runtime.PlayMotionAsync(motionId, vmdPath, loop, playbackRate);
```

位置和世界移动由锚点父节点控制。`MotionCompleted` 仅在真实非循环曲线播放到末尾时发出；`StopMotion` 返回模型绑定姿态，没有伪造自然待机。

现有 Swift `StageAvatarAsset` 投影 `id/format/modelURL/resourceRootURL`，`StageMotionAsset` 投影 `id/format/url/loop/playbackRate/inPlace/strideSpeed`。Rust taskd 当前没有独立的 PMX/VRM 渲染或动作播放 API，须由权威世界与资源接口给出选中的角色/动作；本模块不扫描并替换用户选中项。

## 明确未完成

- 专用 SDEF/QDEF 求解与裙发 Bullet 物理；现有蒙皮走导入器的标准骨骼权重路径。
- 接触地面/坐具的动作支撑、足底 IK、步幅与世界移动速度协同、持物槽位。
- VRM/VRMA：推荐 MIT [UniVRM](https://github.com/vrm-c/UniVRM)，提供 Mac 与运行时 async 导入，但不能代替 PMX。
- 导入分阶段使用 4 ms 时间预算；单次贴图解码/网格构造仍可能超过预算，须真实模型性能采样。

## 验收

用当前选中的真实 PMX 和已安装 BONES VMD，核对贴图、透明材质、角色尺寸、脚底落点、骨骼姿势、面部曲线、循环和一次动作完成回执。同时检查音乐与聊天在导入/切动作期间仍响应。Unity 6000.6 的编译、实际加载和视觉验收尚未执行。
