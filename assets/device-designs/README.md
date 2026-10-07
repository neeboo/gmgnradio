# Unity 系统设备生成验收

`jukebox-v1.png` 与 `wish-machine-v1.png` 是用户指令下生成的设备参考图。
正式模型生成经生产 `WishMachineCoordinator` 的图片注册与授权、
`PropGenerationStore`、Rust taskd、DGX TRELLIS.2，不能使用演示蓝积木替代。

验收使用隔离根 `tmp/device-generation-live-v1`，不领取、不写生产世界、不自动摆放。
固定图片授权 ID 和请求 ID 保证重复观察不新建远端任务。
凭据只读产品 `PropGenerationConfigurationStore.defaultFileURL`，不复制到仓库。

生成程序：`tools/generate-unity-devices-live.swift`。它编译生产协调器与真实 taskd 客户端，
只有附件数据类型声明，不替代网络、任务执行或服务结果。
ready 后核对真实回执的 SHA-256，保存 GLB 与回执；存在碰撞代理时同样核验保存。
任务未完成时不可将 PNG 或只读健康检查当作模型生成成功。

目标高度分别为 1.2 米和 1.1 米；服务尺寸为意图回显，真实尺度必须由 Unity 导入后确认。
模型生成不等于事件绑定完成，点唱机及许愿机业务必须另接系统设备活动契约。

## 2026-10-05 真实生成结果

| 设备 | Rust 任务 ID | GLB SHA-256 | 字节 | 面数 |
| --- | --- | --- | --- | --- |
| 点唱机 | 7B97BC47-505D-4CD0-9878-8869C4184989 | 735d0fcacde112bea3d567c9b5087316c2a8347a0126a76652a67aad506fbced | 4458772 | 19866 |
| 许愿机 | F11CAE06-B586-4A2D-94E5-37C7C7B6FAA1 | cd3b573b908151a31c1c43c80583345c1f240e8f304deea1951f78fae1deae3f | 4431804 | 19663 |

两件均由远端完成后，经 Rust 下载变为 `ready`，runner 退出码 0。
本地另用 `tools/assets/glb_inspect.py` 检查 GLB 结构、嵌入资源、实际面数和哈希。
回执未声明碰撞代理；两件都为 `interaction_status=unbound`、未校准尺度。
没有执行领取、入库、生产空间写入或摆放；这些由统一宿主后续接线验收。

## 许愿托盘 v2

参考图为 `wish-tray-v2.png`。托盘设备作者尺寸为 0.9 × 0.12 × 0.8 米；
生成请求只提交高度意图 0.12 米，模型实际尺度仍标记未校准，需导入后按真实几何核对。

正式生成命令：

```sh
zsh tools/run-unity-device-generation-live.sh /Users/ghostcorn/dev/gmgnradio/target/release/gmgn-taskd --wish-tray-v2
```

此选项只提交新托盘，不重新生成点唱机或 v1 许愿机。
隔离数据根为 `tmp/device-generation-wish-tray-v2`，世界、参考授权与幂等请求 ID 均独立。
Rust 任务 ID 为 `F54C24B3-2EF3-49AE-BD29-197FB22F1C9C`，
远端回执 ID 为 `2c773f3a4e074ea5aa76071105541e23`。
重复观察应复用本根和请求，不能另建生成任务。
runner 核对回执 SHA-256，并在保存 GLB 后读取再次校验；已有不同哈希 v2 文件会保留并拒绝覆盖。
不领取、不入生产世界、不摆放；生成 ready 也不表示设备业务或空间验收通过。

真实生成已完成并经 Rust 下载为 ready，runner 退出码 0。
`wish-tray-v2.glb` 与 `wish-tray-v2.receipt.json` 已保存：

- SHA-256：`7b1fd7424e26a4c00f2e4761865b812b201923cda3c03d8021f6f61ee77cc8f3`
- GLB：3,603,272 字节，20,000 面，1 个 primitive、1 个材质；结构及嵌入资源通过正式 GLB inspector。
- 网格局部边界尺寸为约 1.003589 × 0.148618 × 1.003404 模型单位，`scale_calibrated=false`。
- 回执没有独立碰撞代理。设备导入仍需用真实网格生成碰撞体并按作者尺寸核对，不能宣称已经放好。

回执 SHA、下载文件 SHA、保存后读取 SHA 三者一致；点唱机和 v1 许愿机原 GLB 哈希保持不变。
