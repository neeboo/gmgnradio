# 复杂道具样品：无品牌咖啡机（2026-09-06）

## 结论与边界

已通过现有API一次提交咖啡机参考图，获得`completed`真实GLB。样品通过结构校验、真实鉴权下载、本地独立复核及四视角和无贴图预览。主体、木柄、蒸汽管和冲煮区可辨认，适合作为需要修整的摆件候选；细孔、透明材质和背面存在质量问题。**尺度尚未应用，空间摆放与居民交互未实现**。服务仅输出一体网格，没有自动生成可拆部件、蒸汽嘴关节、开关行为或制作咖啡规则。

本轮未修改服务、转换参数、20 GiB内存上限，也未再次释放旧Comfy缓存、重启旧8188或操作H3；没有新增重试任务。

## 输入与授权

- 参考图由主线程通过内置图片生成工具生成并查看。
- 使用 imagegen 技能与内置工具；[实际参考图提示词](/Users/ghostcorn/dev/gmgnradio/tmp/generated-props/espresso-machine-v1/reference-prompt.md)随本地样品保存，没有使用图片生成 CLI 或读取相关 API Key。
- 本地文件：`tmp/generated-props/espresso-machine-v1/reference.png`。
- PNG尺寸1254×1254，1,628,061字节。
- SHA-256：`9fcc0c187aacfc8de018df418ff8c7d15d1d0923afc4536f43b56a42f9b4acec`。
- 远端输入副本：`/home/spark/gmgn-prop-service/evaluation-inputs/espresso-machine-v1/reference.png`。
- `source.author=gmgn AI-generated reference`。
- `source.license=AI-generated reference; internal evaluation only`，没有虚构CC0或商业发行许可。
- 名称：无品牌咖啡机复杂道具样品；目标高度0.42米，只是输入目标，未写进GLB实际尺度。

## 提交前检查

两个Comfy队列均为空；API `generation.ready=true`、可用内存94.2 GiB。新Comfy进程当前内存10,507,427,840字节；服务历史峰值11,575,586,816字节；`MemoryMax=21474836480`。

按既有接口`POST /v1/jobs`提交一次，固定幂等键`espresso-machine-v1`。一次性提交脚本在`tmp/generated-props/espresso-machine-v1/submit.py`，读取服务器Token文件并直接用于请求，不打印凭据。没有修改`example_client.py`。

## 执行与资源

- API任务：`4783988772c34f44aea79daa5fa66ca5`。
- Comfy任务：`3aaf93a8-8fb3-4005-ade6-5321fae5835c`。
- `execution_start=1788669329029`，`execution_success=1788669447072`，执行时长 **118.043秒**。
- 复用了12个加载/参数节点：`40,279,126,15,193,199,125,108,87,117,288,118`。该结果属于热服务，不能与完全冷启动耗时直接比较。
- 路径：背景去除、DINO编码、TRELLIS形状细化、网格后处理、纹理生成与GLB导出。
- 中间形状7,713,796顶点、15,530,200面，最终简化到19,640面。
- 固定原档位：种子42，上采样1024，重网格256/2次平滑/100万预聚类，目标2万面，纹理/法线1024、AO512×16。
- 采样观察到进程当前内存最高10,699,513,856字节（约9.97 GiB）；服务历史峰值保持11,575,586,816字节（约10.78 GiB），未单独重置采样，故不声称后者是咖啡机独立峰值。

## 正式产物

| 字段 | 实际值 |
| --- | --- |
| 状态 | completed，reason=null |
| API下载 | `/v1/jobs/4783988772c34f44aea79daa5fa66ca5/model.glb` |
| 服务发布文件 | `/home/spark/gmgn-prop-service/data/outputs/4783988772c34f44aea79daa5fa66ca5.glb` |
| Comfy原始文件 | `/home/spark/gmgn-prop-service/comfyui/output/props/4783988772c34f44aea79daa5fa66ca5_00001.glb` |
| SHA-256 | `f8976eb8b54c7aba93f7a008d070d3d42737c5e22175a353eb275d7097bd67b3` |
| 字节数 | 3,744,556（约3.57 MiB） |
| 三角面 | 19,640 |
| 结构 | 1 primitive、1材质、5 accessor、无场景变换 |
| 局部XYZ尺寸 | 0.62199056 × 0.74523231 × 1.00579435 模型单位 |
| 局部min | (-0.30935502,-0.37417376,-0.50287867) |
| 局部max | (0.31263554,0.37105855,0.50291568) |
| 产物预算 | ≤32 MiB、≤22000面；本件通过 |

局部Z轴最长，因此先预览再确认上轴。通过 Blender 按 glTF 约定导入的四视角，可见机器底座在下、顶盖在上，确认本件源 GLB 的 Y 为上轴。高度约0.745232模型单位，0.42米目标对应约0.563583倍；换算宽约0.35054米、含突出木柄的深约0.56685米。换算值仅作后续摆放建议，未修改原GLB或凭预设声称恢复了真实物理尺寸。

### 真实鉴权下载

通过现有`example_client.py download --job 4783988772c34f44aea79daa5fa66ca5`调用Bearer鉴权API，下载到DGX新临时文件`/tmp/gmgn-coffee-api-download.RqZCUg`。下载结果3,744,556字节，SHA-256为`f8976eb8b54c7aba93f7a008d070d3d42737c5e22175a353eb275d7097bd67b3`，与正式发布文件、API检查结果一致。没有重提或执行新生成。

主线程另已完成本地获取与独立结构检查/哈希核对，结果一致。`height_meters=0.42`始终是目标待校准值，本轮没有修改GLB。

## 实际 GLB 视觉检查

本地文件：[model.glb](/Users/ghostcorn/dev/gmgnradio/tmp/generated-props/espresso-machine-v1/model.glb)。使用 Blender 5.2 无窗口导入；两线程CPU、640×640、12采样渲染，未启动GMGN、未操作桌面。材质视图保留原GLB的三张1024×1024内嵌图片；另以统一灰色材质渲染一张，只用于区分几何与贴图，不修改原资产。

- [正面斜视](/Users/ghostcorn/dev/gmgnradio/tmp/generated-props/espresso-machine-v1/view-1.png)：整体轮廓、木柄、冲煮头、控制钮和蒸汽管保留，操作区有明确空间。
- [后侧视图](/Users/ghostcorn/dev/gmgnradio/tmp/generated-props/espresso-machine-v1/view-2.png)与[背面](/Users/ghostcorn/dev/gmgnradio/tmp/generated-props/espresso-machine-v1/view-3.png)：未提供背面参考，模型补出布状部件；不视作依据充分的重建。水箱呈不透明外观，未保持输入的通透感。
- [另一侧](/Users/ghostcorn/dev/gmgnradio/tmp/generated-props/espresso-machine-v1/view-4.png)：机壳大形状连续，但边缘和接水盘细节不够规整。
- [无贴图几何](/Users/ghostcorn/dev/gmgnradio/tmp/generated-props/espresso-machine-v1/geometry-only.png)：木柄、冲煮头、按钮凸起和蒸汽管具有几何形状；接水盘主要保留凹槽，未验证为真实贯通孔；压力表读数主要依赖贴图。蒸汽管与后部的分离程度仍需在交互加工时检查。

本件导入后只有一个网格对象，因此没有自动得到可独立转动的旋钮、可取走的手柄或可打开的水箱。视觉损失是本次完整生成与加工流程的结果，未分离评估生成、重网格、减面各自的影响，不将所有问题归因于2万面预算。

## 主线后续验收

1. 修整无依据的背面部件，按需要拆分可动部件；优先用额外参考约束背面，再比较现有档位，避免直接扩大面数与客户端成本。
2. 确认上轴、缩放和地面/桌面接触，再生成保守碰撞体与角色站位。
3. 现有API仅返回`inspect/place`用途候选与`interaction_status=unbound`。咖啡机动作及场景API需单独绑定，不能因造型像咖啡机就声称居民已经会使用。
4. 样品来源限定内部评估；若进入素材服务或交易市场，再进行模型和参考图许可审核。

3D推理使用现有DGX，未调用第三方云端3D生成API；参考图使用内置图像生成，其额度或计费本轮未读取，不宣称全链免费。证据只证明这张复杂参考图在当前固定档位下生成并通过所列检查，不代表任意物品都会保持功能性结构。
