# 居民思考动作

2026-09-07：本目录已退出应用打包及运行时接线，仅保留旧素材作历史核对。
居民思考、待机和持物改读已安装的 BONES 动作包；来源清单为
`tools/motion/fixtures/bones-resident.json`。不要重新启用本目录中的手写动作。

这两个小文件由项目自有关键帧生成，没有使用 BONES、ARDY 输出或第三方动作数据。

- 来源：`tools/motion/fixtures/resident-thinking.json`
- 重建：在仓库根目录运行 `python3 -m tools.motion.build_resident_thinking`
- 校验：`python3 -m unittest tools.motion.tests.test_resident_thinking`
- VMD 对应 PMX，VRMA 对应 VRM；都通过现有装载与重定向路径播放。
- 循环四秒，低头并屈右肘；没有根位移或腿部轨道，不能用于导航或跨越。
- 用真实模型请求开始／结束状态触发，正式空间活动优先。停止时恢复原先动作。

已经验证文件与生成源一致；尚未通过真机确认不同模型的手臂位置和姿态观感。
