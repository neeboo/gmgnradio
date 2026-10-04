# 真实 SPZ 空间候选

采用 Aras UnityGaussianSplatting 1.1.1，固定 revision `2c6fed37da67a217367261fcfcd3316d34c73e76`。UPM 包保留原有 MIT LICENSE.md，不复制第三方代码进本目录。

已有 Swift 空间通过 SplatIO/spz-swift 解码；没有现成 Rust→Unity SPZ 运行时接口。本阶段直接使用成熟 Unity Gaussian 解码/渲染候选，避免重写椭球投影和 GPU 排序。

## 生成流程

1. 使用 Unity 6000.6.0f1 Editor `-batchmode` 调用 `GMGN.UnityPlayer.Editor.GaussianWorldBootstrap.Install`，不要 `-quit`；Client.Add 异步完成自行退出。
2. 设置 `GMGN_UNITY_CABIN_SPZ` 指向 `apps/macos/Resources/Worlds/marble-living-cabin/scene-500k.spz`，调用 `PrepareCabin`。此真实文件是 SPZ v2、SH0、500000 个椭球；固定上游 importer 对 SH0 无条件读取不存在的 SH，导致 job 异常却继续产出全零位置。`CabinSpzConversion` 在准备阶段转成合法二进制 PLY，保留位置、log尺度、四元数、DC颜色及 logit opacity，SH0高阶补零，再走上游成熟 Gaussian Creator。非 v2/SH0 输入明确拒绝，未实现任意 SPZ 解码器。
3. 生成数据位于本目录 Resources/GaussianWorld，已忽略 Git；构建前重做生成步骤。输入是已有真实 500k SPZ，不使用碰撞 GLB 作为颜色背景。
4. 运行时添加 `GaussianWorldView`，调用 `ShowCabin()`/`Hide()`。`ShowCabin` 成功只表示 renderer 已启用，尚不能当作视觉验收。

当前没有用户在 Release 中导入任意 SPZ 的流程；该能力需后续运行时 importer 或构建资产服务，不能把 Editor importer 当成用户功能。

## 图形约束与验收

- 真实椭球 splats 渲染模式为 Splats，不能选择 DebugPoints 冒充。
- Metal/D3D12/Vulkan；Compute 不支持就报错，无点云兜底。
- 为当前 URP renderer 添加 GaussianSplatURPFeature。MSAA关闭、HDR开启；RenderGraph Compatibility Mode 必须关闭。只修改当前项目使用的 URP 资产。
- 上游自带 GPU 排序、GaussianSplat.CalcView/Draw/Compose Profiler marker。500k真实场景须测 GPU帧时长、主线程、窗口和原生全屏60fps；未测不能声称达标。
- 用原 SceneKit/Metal 空间对照坐标朝向、地面、遮挡、相机；Gaussian 不写深度，透明物体遮挡仍有上游限制。
- prefab 校准读取源 `marble.json` 的 framing。SPZ RUB→Swift RDF 翻Y/Z，再 RDF→Unity 翻Z，净翻Y；尺度 `(s,-s,s)`，偏移 `(-origin.x,-origin.y,+origin.z)*s`，WorldBridge 不再重复转换背景。
- 许可证：renderer 为 MIT；源空间资产的来源许可独立核实。第三方 MIT 文本由 UPM 包原样保留。

来源：
https://github.com/aras-p/UnityGaussianSplatting
https://github.com/aras-p/UnityGaussianSplatting/blob/main/docs/render-pipeline-integration.md

可复现命令（从仓库根执行；同一项目不能并发 Editor）：

```sh
/Applications/Unity/Hub/Editor/6000.6.0f1/Unity.app/Contents/MacOS/Unity -batchmode -projectPath "$PWD/apps/unity-player" -executeMethod GMGN.UnityPlayer.Editor.GaussianWorldBootstrap.Install -logFile "$PWD/tmp/unity-gaussian-install.log"
GMGN_UNITY_CABIN_SPZ="$PWD/apps/macos/Resources/Worlds/marble-living-cabin/scene-500k.spz" unity run "$PWD/apps/unity-player" --editor-version 6000.6.0f1 --timeout 300 -- -executeMethod GMGN.UnityPlayer.Editor.GaussianWorldBootstrap.PrepareCabin -logFile "$PWD/tmp/unity-gaussian-prepare.log"
```

Prepare 成功必须同时满足：进程 exit0、日志无 job exception、生成资产 count500000且bounds非零、prefab持有真实Splats模式及校准矩阵。首次上游直读虽exit0，已判失败，不能复用全零输出。

数值 readback：从仓库根执行 `node apps/unity-player/Assets/GMGN/GaussianWorld/verify-cabin-conversion.mjs`。2026-10-04 全部500000点对比通过：位置/log尺度/SH误差0，DC最大绝对误差1.052e-7、opacity 4.013e-8、四元数4.479e-6、单位四元数模长1.147e-7。此结果证明转换数据，不证明GPU画面或60fps。
