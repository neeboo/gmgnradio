# Unity 空间迁移断点

## 已实现

- Unity 6000.6，官方 Package Manager 安装 glTFast 6.20.0、Newtonsoft JSON 3.2.2。
- PortableWorldPackage 校验备份文件集合、SHA256、路径及引用；按 Rust 记录规则物化世界，排除 tombstone。
- GLB 真实加载，生成物件以 assetID 的 SHA256 精确解析 blob；应用朝向、有效尺寸及底部中心，不重复应用派生 scale。
- WorldRuntimeBridge 显式备份入口、背景加载、相机恢复及空间切换；Rust 快照/提交经宿主后台队列，保留 CAS 和请求编号。
- AudioSculpture 改为 Compute 更新和单批 GPU 绘制，未完成所有歌词风格迁移。

## 验证范围

- Unity 恢复校验退出码 0：tmp/unity-world-recovery-checks-v2.log。
- Swift 宿主 Release 构建退出码 0：tmp/unity-world-host-build.log。
- 独立 Unity v15 Release 构建退出码 0：tmp/unity-world-player-v15-build.log。
- 上述结果不代表真实用户空间运行验收通过。
- v16 实际启动，便携备份 v3 内 7 个真实 GLB 哈希匹配；加载 5 个启用物件。当前画面空黑，定位为相机额外旋转 180 度，正在修复，尚未视觉通过。
- 备份工具新增显式 --blob-file，避免导出整个 TaskService；18 个测试通过，实际 7 个引用模型缺失数 0。用户备份只在 tmp，不进入 Git。
- SPZ 上游导入器遇到当前文件的零阶 SH 数据抛 IndexOutOfRangeException，虽然 Editor 退出码为 0，生成资产全部零坐标，判定失败。正在补保留完整高斯参数的转换和非零 bounds 校验；不能把该导入结果交付。
- 后续已以合法 PLY 转换修复 SH0 导入，500000 点位置/尺度无数值误差，四元数最大误差约 4.5e-6。v17 Release 实际画面已显示高斯生活舱和 5 个物件；模型黑色/底部品红材质异常尚未通过。日志 tmp/unity-space-runtime-v17.log，窗口模式稳定段约 58–59fps；切换/全屏有慢帧，不宣称完整性能通过。

## 下一步

1. 用真实世界的只读便携备份，在隔离 App 启动并检查背景、物件、相机及模式切换。
2. 验证 Rust 权威投影与备份版本一致性，再接编辑、吸附、旋转及保存回执。
3. 迁移角色、动作、手持、设备事件与高斯空间；当前不能声称完整支持。
4. 实测 GPU 点阵、所有歌词效果、音频与聊天，保持 60fps。

运行入口：GMGN_UNITY_WORLD_PACKAGE、GMGN_UNITY_WORLD_ID；背景引用通过 GMGN_UNITY_WORLD_SCENE_REFERENCE 指向备份 referenceBindings 的原始引用。不写入备份，不启动自主行动，不覆盖已装 App。
