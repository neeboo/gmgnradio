# 咖啡机分件实测与 CAD 路线选择

日期：2026-09-06。范围：用户授权的一件咖啡机分件研究实验，及追加的 CAD 路线研究。没有接入正式 API、安装客户端、改变生活舱或运行居民交互。

后续产品决定：用户已将 CAD／Agent 拆装明确列为高级建造模式，当前先交付图片生成的简单许愿机。下文“下一轮 CAD 对照”是当时研究建议，已不再作为近期实施排期；实际顺序采用[许愿机计划](../2026-09-06-wish-machine-and-build-modes.md)，实验事实保持不变。

## 决策

本轮选择 PartField 做已有网格的分件实验，已经运行成功。**速度、保材质拆分、按原位重新组合通过；自动产出可用功能零件未通过。** 暂不把任何分件模型设为正式素材服务的默认供应商。

对需要拆装的规则道具，下一轮优先比较「Agent 编写参数化 CAD 零件＋装配关系→GLB」。先只做旋钮、接水盘、冲煮手柄。已有生成外壳可以继续使用，复杂装饰物也不必强制转 CAD。此选择是基于本件分割结果与官方 CAD 文档的工程判断，CAD 样品尚未生成，不能称为 CAD 质量已验证。

## 为什么先试 PartField

- 直接处理现有 GLB；关闭重网格与预处理，可把逐面标签回映到原始三角面。
- 当前官方核心模型可用 PyTorch 运算实现，适配 DGX Spark 的依赖少于 P3-SAM 所用 Sonata、稀疏卷积等组件。
- Hunyuan3D-Part 的分件／补面与 PartCrafter 的重新生成不等价。本轮限定保留同一原始模型，不混入形状重新生成来掩盖分割问题。
- PartField 官方许可证仅限非商业研究教育。本次目录及产物明确标为研究用途，不接入收费素材服务。P3-SAM 实际加载 Sonata 权重，后者也有非商业限制，不能只依据混元顶层许可证判断整条管线。[PartField](https://github.com/nv-tlabs/PartField)、[许可证](https://github.com/nv-tlabs/PartField/blob/main/LICENSE)、[P3-SAM 加载代码](https://github.com/Tencent-Hunyuan/Hunyuan3D-Part/blob/main/P3-SAM/model.py)、[Sonata](https://github.com/facebookresearch/sonata#license)

## 固定输入与运行环境

- 输入：`tmp/generated-props/espresso-machine-v1/model.glb`，19,640 个三角面、16,154 个顶点。
- 输入 SHA-256：`f8976eb8b54c7aba93f7a008d070d3d42737c5e22175a353eb275d7097bd67b3`。
- 远端独立目录：`/home/spark/gmgn-partfield-eval`，约 1.4 GB，保留供复现。
- 官方代码提交：`373025dbd283bb44cc4a6dc78c99994dbc91de32`。
- 官方权重 SHA-256：`463efc8a3afd3913142aa025e0125c00f16ef452b8de6a132ebe32bbe7877ee4`。
- Python 3.12、Torch 2.12.0+cu130、ARM64／GB10；独立环境，没有修改现有服务环境。
- 单进程、CPU 限两核、20 GiB 内存上限、低优先级；运行日志峰值约 3.1 GiB，无新增进程交换内存。
- 结束后新 Comfy 与 API 均 active，8190 队列为空，可用内存约 93 GiB。未停止现有服务、未释放其他任务模型缓存。

## 实际适配与耗时

没有宣称运行完全未经改动的官方演示：轻量入口提取官方模型构造器，排除训练和不用的重网格依赖；全部权重 `strict=True` 匹配。`scatter_mean` 用原生 `scatter_add` 实现，唯一索引、重复索引、空桶三类手算对照通过。面采样使用等分布重心采样，未逐点复现官方随机数序列。

- 100,000 个表面点，每面 500 个采样点，输出 `19640 × 448` 特征。
- 特征提取 **2.556 秒**。
- 模型加载、提取与 KMeans 的 4／8／12 档聚类合计 **8.830 秒**；不含下载、安装与预览。
- 已有特征再运行官方 option1、MST／KNN 连通关系的层次聚类，另 **1.855 秒**，输出同样三档。
- 固定随机种子 0。没有对混元进行同机速度对比，因此不作模型速度排名。

## 产物与验证

本地目录：`tmp/partfield-eval/`。`coffee-results/report.json`、`hierarchy-report.json` 保存运行参数。`exports/{kmeans,agglo}/k{4,8,12}/` 各有组装、拆开两个 GLB，共 12 个文件。

主代理重新运行 `export_parts.py` 并检查实际图像；导出只新增部件节点和索引块，原二进制块作为完整前缀保留。检查每个源面 ID 恰好属于一组，面索引集合、属性、UV、法线、切线、材质和三张内嵌图片均未改变。节点保存研究标记与归位变换。应用爆炸图节点的归位变换后，逐项比较组装图真实 TRS 与 mesh 引用；错误位置和错误 mesh 引用负例被拒绝。

代表产物：

- [8 件组装 GLB](/Users/ghostcorn/dev/gmgnradio/tmp/partfield-eval/exports/agglo/k8/assembled.glb)，SHA-256：`cf7390da2d026a2e85599fe86544d65abd7926d3cbee5d2afe5ffa59f89a5d08`。
- [8 件拆开 GLB](/Users/ghostcorn/dev/gmgnradio/tmp/partfield-eval/exports/agglo/k8/exploded.glb)，SHA-256：`347d50790beb5d31aa912ef39022a8aa2b96da9ce7b3427ee20eb414366e8dd5`。
- [实际 GLB 组装图](/Users/ghostcorn/dev/gmgnradio/tmp/partfield-eval/exports/agglo/k8/assembled.png)。
- [实际 GLB 拆开图](/Users/ghostcorn/dev/gmgnradio/tmp/partfield-eval/exports/agglo/k8/exploded.png)。
- [12 文件验证报告](/Users/ghostcorn/dev/gmgnradio/tmp/partfield-eval/exports/validation-summary.json)。

预览用 Blender 5.2、CPU 两线程、12 采样、800×700，无窗口，不启动游戏。导入器去掉四个同位置重复三角面，预览共 19,636 面；已逐面确认所有独有三角面仍存在。正式 GLB 绕过 Blender 二次导出，仍完整保留 19,640 面。此差异已记录，不能把预览面数误称为原始文件面数。

## 视觉判断与停止条件

- 4 件：过粗，手柄、托盘及其他功能件仍与大块表面连在一起。
- 8 件层次聚类：机身上部、水箱、底座等大区域分离较清楚，适合作为人工选择的起点。
- 12 件：出现更细的分离，但水箱和外壳也进一步碎裂，增加零件数没有自然得到正确装配结构。
- 两种聚类都存在锯齿边界；旋钮没有作为完整独立件；切开后的内部没有补面。手柄有时只分出握柄，滤杯和其他表面仍粘连。

因此，本件未通过「手柄、接水盘、旋钮均能作为完整功能部件独立使用」的标准。未补面、未推断关节、未测试卡扣或物理碰撞。保存位置后能恢复外观，不能等同于机械装配正确。此次不继续增加聚类档数或安装第二个大模型。

## CAD 的下一轮位置

CadQuery 可建立命名装配并直接导出 GLB；保留 CAD 脚本作可编辑源文件，GLB 作客户端资产，连接点、运动轴与限位另存。毫米与米需明确转换。CAD 本身不会从一张图恢复隐藏结构、真实尺寸或制造间隙。[装配](https://cadquery.readthedocs.io/en/latest/assy.html)、[导出](https://cadquery.readthedocs.io/en/latest/importexport.html)

CAD-Recode 与 Cadrille 已公开点云／图像等到 CadQuery 的研究实现，但未核到可直接输出本件语义装配树、关节的完整管线；相关权重有非商业限制。可研究，暂不部署。[CAD-Recode](https://github.com/filaPro/cad-recode)、[Cadrille](https://github.com/col14m/cadrille)

建议对照限定三个命名部件，采用明确尺寸与接口，检查封闭实体、安装位置、拆装空间及导出尺度。由已有 Agent 生成 CAD 代码时，应在隔离执行环境中建模、测量、渲染和修改；不让模型输出代码直接操作居民世界或个人文件。咖啡机道具使用 GLB，VRM 留给需要人形骨骼、表情等规范的角色，不把普通 CAD 道具强制转 VRM。
