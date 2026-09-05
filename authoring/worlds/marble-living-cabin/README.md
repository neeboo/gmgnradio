# Marble 飞船生活舱

用户采纳的路线：用参考图快速生成可观察的生活空间，再叠加独立角色和交互物件。本包不使用几何生活舱的墙体、地板、床或控制台。

## 来源与生成

- 原参考：`reference-user.png`。
- 生成输入：`reference-empty.png`；通过图像编辑移除参考图中的角色和前景圆柱，保留建筑、材质、灯光与构图，避免角色和设备被烘焙进环境。
- 世界：`84503420-3010-4944-8fde-2f383cd08ebe`，模型 `marble-1.1`。
- 操作：`b6c0e1f5-c01f-4453-ae7f-b3e3015fe852`，完整回执在 `operation.json`。
- 服务端创建时间：2026-09-05 04:38:23 UTC；生成完成更新时间：04:43:48 UTC，约 5 分 25 秒。
- 本次只提交一次生成。账户积分从 6250 降到 4670，消耗 1580；没有购买高清网格或追加生成。
- `assets/` 保留 500k / 100k SPZ、碰撞 GLB、全景和缩略图。应用采用 500k SPZ（约 7.3 MiB）和 GLB（约 4.1 MiB），不把全景图当作游戏背景。
- 私有生成记录仅作本地研发凭据；不代表参考图或相关角色拥有商业授权。未公开发布世界。

## 坐标与物件

`layout.json` 是本次实测布局。SPZ 读取器已经做 RUB → RDF 转换；GLB 采用 `flipYAndZ` 与其对齐。统一转换为：

`gameplay = (convertedSource - [0, -1.432358, 0]) * 2.4251627922058105`

生成结果的米制系数原为 1.2125813961029053，但全景小门与真实碰撞网格的射线测量显示，左右小门分别仅约 1.069 米和 0.971 米。因此 1.1.0 包采用原环境两倍尺寸，角色仍保持 1.7 米，独立设备不放大。测量脚本为 `probe-door-scale.swift`；全景方向通过门底贴近地板验证，缺少供应商外参，结果包含点选和网格简化误差。各点上下左右扰动后的两倍门高范围分别为 2.043–2.219 米和 1.782–2.094 米。

这是按门高采用的场景校准：生成建筑内部比例并不一致，校准后主舱最高约 5.3 米，不能同时满足原提示中的 3.2 米层高与 7 米房宽。没有追加付费生成，也不走旧的最大边长压缩到 4 米逻辑。地面有厘米级起伏，各活动点分别从真实 GLB 查询高度。碰撞网格包含 161600 个三角形。1.1.0 使用新的空间状态目录，旧 1.0.0 存档保留，避免旧坐标套入新尺度。

点唱机是现有 SceneKit 工厂生成的独立实时物件，仅复用设备本身，底面中心为原点，高 1.23 米，正面朝 -X。设备位置、角色操作点、设备碰撞体均来自同一布局。生成环境负责视觉和地面；设备只阻挡，不提供可站立地面。

当前只开放三个活动：待机、散步、走到点唱机听音乐。到达点唱机后调用现有播放器继续播放；没有可播放曲目时给出提示，不伪报成功。尚未增加自由装修编辑器、物件市场或新的手部插唱片动画。

## 复现

从仓库根目录执行：

```sh
node tools/marble/world.mjs poll --operation-id b6c0e1f5-c01f-4453-ae7f-b3e3015fe852 --out authoring/worlds/marble-living-cabin/operation.json
node tools/marble/world.mjs download --world-file authoring/worlds/marble-living-cabin/operation.json --out-dir authoring/worlds/marble-living-cabin/assets
swift authoring/worlds/marble-living-cabin/probe-collider.swift
node authoring/worlds/marble-living-cabin/build-package.mjs
```

不需要重新执行付费 `generate`。应用包输出在 `apps/macos/Resources/Worlds/marble-living-cabin`；运行时使用内置资源，无需访问 API 或钥匙串。

## 验证范围

- 原生包测试检查资源哈希、正式活动与操作点，并解码真实 GLB 检查地面、胶囊碰撞和路线。
- `probe-agent-interaction.swift` 使用真实 `WorldAgentContext` 和生成网格、独立设备碰撞，已实际完成 `music.listen` 的 `approach → enter → loop`；进入阶段显式设为 0.6 秒。
- 采用包加载时显式设置碰撞源为 World Labs OpenCV。测试使用真实世界解码、加载和资源查询函数，防止普通 glTF 默认值导致运行时碰撞翻转遗漏。
- 工具测试使用模拟网络检查生成提交、失败和下载行为；真实生成回执独立保留。
- 轻量渲染测试执行设备几何与坐标变换，部分管线检查为静态接线检查，不能代替画面验证。
- 生成全景和缩略图是供应商预览，不等于应用中角色、设备、遮挡和动作全部验收。
