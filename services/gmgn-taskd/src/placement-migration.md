# WorldRuntime 摆放规则 Rust 迁移边界

本模块是纯数学、serde 输入输出，不读磁盘，不依赖 Unix，不写 world state。
`placement::evaluate(EvaluateRequest) -> EvaluateResult` 的坐标保持旧 Swift 右手 Y-up。
Unity 负责转换 Z 和 yaw，不能将预览中心误当格子最小角锚点。

| Swift source | Rust port |
| --- | --- |
| `WorldPlanarFootprint.center` | 最小角锚定，旋转后的半尺寸中心偏移 |
| `WorldPlanarFootprint.columns` | 4 轴 SAT，边界相切不占格，最多 4096 查询格 |
| `PropPlacementEvaluator.evaluate` | 全占地列 bounds / 同层 / 2cm 高差检查；缺几何拒绝 |
| `WorldPropMeshClearance.canPlace` | 三角形对 yaw 盒 13 轴 SAT，2cm 接地容差 |
| `WorldPropBoxOverlap` yaw 分支 | 5 轴 OBB SAT；接触不算重叠 |
| `WorldPropObstacleOverlap.proxyMesh` | 三角形 SAT；闭合代理盒心射线奇偶判断 |

协议输入 grid 由 `support_grid::derive` 从真实三角形派生并经过种子 BFS 过滤，不是任意平面。
`triangles` 是同一碰撞几何的局部查询结果；空值给 `noSupport`，不会放行。
代理 mesh 的 `isClosed` 默认为 false，仅真实通过闭合校验的代理应传 true。

## 明确未迁移

- `PropSupportGridBuilder` 的多层扫描、胶囊可站、BFS、家具带保留已迁入 `support_grid.rs`，有 8 项回归；真实空间派生和性能仍须实际验收。
- `WorldPropWallGrid` 的真实三角形墙面候选和离墙逐格搜索。
- `WorldPlacementRouteMap` 居民通路/活动入口连通性。
- 非 yaw OBB 的 Swift 保守 quaternion fallback：当前 API 仅接受 yaw，不能给倾斜物件丢弃旋转后调用。
- GLB 代理解码、归一化、闭合校验、摘要注册，当前只接受已验证世界空间代理。
- 源碰撞几何空间分桶缓存。调用方应发送局部三角形，不能每帧传全室 16 万面。
- 权威世界状态/候选输入一致性核验由协议接入层负责；本函数只是显式输入几何判定，不构成可信提交授权。

因此该模块测试通过不等于完整旧系统迁完，更不等于真实 Unity 鼠标摆放验收。
