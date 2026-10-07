# Unity 许愿业务桥接线

`UnityWishMachineBridge.swift` 复用原 `WishMachineCoordinator`、`ResidentWishMachineTools` 和 Rust 任务/世界权威；不创建新委托数据库、不启动 taskd。

## 唯一共享服务

由宿主 composition 创建一个明确数据根的 `PropGenerationStore` 和 `WishMachineCoordinator`。协调器 `canClaim` 必须使用同一 `WorldAgentContext` 的真实活动和 Unity 渲染回执：当前 `wish_machine.collect`、`loop`、已摆设备的真实领取点距离不超过 0.25 米。按主代理本轮明确决定，outputAvailable 可由 matching 正式 ready job、对应完成回执和已下载输出文件权威投影提供，不要求托盘 UI 回执。产物可用与角色到达仍各自验证，设备点击或任务 ready 不能替代真实活动/距离证据。

```swift
let registrar = UnityWishInventoryRegistrar(root: root, worldID: worldID, store: store)
let wish = UnityWishMachineBridge(coordinator: coordinator,
    worldID: worldID, residentScope: residentScope,
    registerInventory: registrar.register, inventoryReadback: registrar.readback)
wish.onInventoryConfirmed = { objectID in /* 请求正式 world.snapshot 刷新投影 */ }
```

Registrar 实际读取模型字节、核对任务回执 hash/bytes，使用既有 `GLBColliderDecoder` 测量节点变换后的 GLB，复用 `WorldPropOrientationPolicy` / `WorldPropSizePolicy`，使用 `WorldSimulation.applyPropLayout(.register)` 及 `WorldAuthorityClient` CAS 写入。完整三轴请求不会被 provider 权威尺寸覆盖。声明的碰撞代理必须本地存在且 hash、bytes、三角形数匹配。压缩/非支持 GLB 解码失败可见拒绝，不使用虚构 bounds。

入库产生 disabled 的正式库存物件。它不等于已摆放或已手持。已有库存按 sourceWishID/assetID 去重并保留用户尺寸与位置；墓碑不自动重建。CAS 回执之后仍进行独立权威读回，完全一致才确认。

## 原生工具

每个人类轮创建原 `ResidentWishMachineTools` 租约，使用 `wish.tools(for: lease)` 注册其正式 schema/validation/handler。生成前由宿主对真实参考图和明确制作指令调用原 coordinator authorize/register 接口；普通聊天不能无条件生成花费授权。提交、重试和领取均保留原 requestID/authorizationID/作用域规则。

`claim_wish_output` 工具成功后由装饰器执行正式入库及读回；失败返回 `inventory_not_confirmed`，说明“已经领取，入库尚未确认”，无需重新生成或领取。

## Host / Native / UI

- Host `command` 转发 `wish.status`、`wish.claim`、`wish.retry`、`wish.inventory.retry`，均要求非空 requestID；后三者要求 wishID。返回 true 仅为受理。
- Host snapshot 添加 `wish.snapshot()`，Native 将该对象转事件；紧凑 generation/pending pulse 不清空列表。
- `WishMachinePanel(parent, request, openChat)` 提供 Show / Hide / Update。生成按钮仅打开正式聊天；打开面板只查询，未到达领取点时禁用领取。
- snapshot entries 包含 wishID/objectID/name/stage/claimAvailable/inventoryRegistered；关闭宿主调用 `wish.close()`，禁止启动下一步写入。已经发出的 Rust CAS 可能完成，不声称取消可以回滚。
- UI 输入屏蔽须识别 `wishMachinePanel` 背景，避免穿透空间拖动。

## 仍需实际接线 / 验收

正式参考图登记及授权、共享活动 context、已放设备功能点/正式 ready 输出投影、Unity 动态下载资产的可信 resolver 由各模块接线。固定备份包的 ResolveAssetID 不能解析新生成文件；需要以已验证 hash/path 的正式资源入口注册新资产，不能扫描路径替代。没有这些入口不可声称完整业务通过。

隔离边界回归（模拟任务/权威传输，生产 bridge 和真实 WorldRuntime 编译）：

```sh
swiftc -emit-library -emit-module -module-name WorldRuntime apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/*.swift -emit-module-path /tmp/WorldRuntime.swiftmodule -o /tmp/libWorldRuntime.dylib
swiftc -I /tmp -L /tmp -lWorldRuntime apps/macos/UnityHost/UnityWishMachineBridge.swift tools/test-unity-wish-bridge.swift -o /tmp/gmgn-unity-wish-regression
DYLD_LIBRARY_PATH=/tmp /tmp/gmgn-unity-wish-regression
```

覆盖到达拒绝、已领取但读回失败、入库重试不重复领取/提交、重建桥库存恢复、关闭拒绝请求。真实生成服务、隔离 Rust 持久化、Unity 模型出现及重启恢复需要另行端到端验收，未包含在上述 PASS 中。
