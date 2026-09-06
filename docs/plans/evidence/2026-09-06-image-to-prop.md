# DGX 图片转道具服务验证（2026-09-06）

## 已完成与未完成

已部署独立 Comfy 后端及带鉴权的异步 API，5个模型全部下载完成。首件最初因可用内存不足等待；用户随后明确授权释放旧Comfy模型缓存，原任务自动继续并已成功导出、校验和发布真实GLB。**图片转道具生成已通过首件验收，空间内视觉、尺度、碰撞和交互接入仍由主线验收。**

## 原环境只读检查

- 主机：`dgx_spark` / `spark-836a` / `192.168.1.227`，ARM64，NVIDIA GB10。
- 根盘：3.7 TiB，总剩余约 2 TiB。
- 原 ComfyUI：`8188`，源码 `5599a05`（2026-08-07），队列检查均为空。
- 原 H3：`9000/api/h3/health`返回 `{"status":"ok"}`。
- 原 Comfy 进程 PID `911345`，RSS 约 71,256,024 KiB。整机 121 GiB 内存，约 102—103 GiB 使用，17—18 GiB可用；GPU利用率0%不代表模型已释放。
- 初始阶段未重启、卸载、升级或停止上述服务，未调用旧Comfy释放模型缓存，也未读取其凭据。后续仅在用户新授权下执行官方缓存释放，详情见“授权后首件真实生成”。

## 工作流与隔离部署

用户指定[工作流](https://comfy.org/workflows/920c795f693a-920c795f693a/)是编辑器格式（0.4），下载源随仓保存在 `tools/assets/workflow.source.json`。

- SHA-256：`a4ffdea180901016255224df7e509f7db0fe2325f688a8c4376bf153dcf1b7a0`。
- 旧服务缺 TRELLIS.2、Pixal3D、网格后处理节点。
- 官方 `v0.33.0`标签也未包含本图全部节点，因此独立 checkout 当日官方提交 `15eb748b3ec5f8a0a2d470b7fb280e2d7579f916`，不修改旧 checkout。
- 目录 `/home/spark/gmgn-prop-service`；独立 venv 复用已装 Torch `2.12.0+cu130`，新 Python 包仅写此 venv。
- 新后端 `127.0.0.1:8190`，关闭所有自定义节点，线程数2、低显存模式、保留4 GiB。
- 新后端进程级内存限制：`MemoryHigh=19327352832`、`MemoryMax=21474836480`、`MemorySwapMax=0`，真实systemd回读一致。未假设这保证模型一定能生成，超预算会失败。
- 新 API `127.0.0.1:8191`，仅回环监听，Token 文件0600；拒绝浏览器 Origin，不提供无鉴权外网访问。
- 用户级服务 `gmgn-prop-comfy.service`、`gmgn-prop-api.service`均已启动。API enabled，后端由它依赖启动。

模型串行下载到新目录，不改旧模型库。5个已完成权重：

| 文件 | 字节 | SHA-256 |
| --- | ---: | --- |
| trellis_2_texture_vae_bf16.safetensors | 948461364 | 714e5ebf094a610e12a8e3b5175c18a62f37f6ea4218acb6073644456b73ab0e |
| dino_v3_L_naf_fp32.safetensors | 1215214176 | 4ad2ec4e0879a5b5b04cd97325cc37da954a7b6edca5170b86510f17f2b2290f |
| trellis_2_shape_vae_bf16.safetensors | 1095844024 | de0cb4949a76c59ee5c091a995a69bcc8c51d5aeda939f0c641a50d2a72341f4 |
| birefnet.safetensors | 444473596 | 9ab37426bf4de0567af6b5d21b16151357149139362e6e8992021b8ce356a154 |
| trellis_2_int8_convrot.safetensors | 5253048192 | d01952ad137213f6a868f86b6b877026276f84af5eec23069217475a0bad3a31 |

完整下载记录位于 `/home/spark/gmgn-prop-service/comfyui/model-receipts.json`。独立服务目录磁盘占用约8.8 GiB。

## API 实际验收

`example_client.py submit`通过 API 创建：

- 任务 ID：`d30c33db0665442084444263cecede0e`。
- 参考：脚本绘制的原创无品牌蓝积木，输入授权声明 CC0。
- 用户目标高度：0.3米，不能当作从单图推断出的真实尺度。
- 首次返回 `queued`；模型齐全后的第一阶段回读是 `waiting_resources` / `shared_memory_busy`，当时没有宣称生成成功。
- 幂等键 `original-blue-block-v1`，重复提交复用同任务，不二次调用模型。

第一阶段最后 `/health` 回读：`status=api_ready`、`generation.ready=false`、`reason=shared_memory_busy`、`available_gib=17.9`、`minimum_gib=24`。API 每30秒确认旧、新 Comfy 队列空闲与可用内存，既有单件任务继续排队，没有增加新任务。运营者获得用户许可并手工释放旧Comfy驻留缓存，或其他工作负载自然退出后，内存达到门槛即可自动继续；服务本身不执行释放。

原8188最后仍返回空队列，H3仍返回`status=ok`；新两个进程均active，8190/8191只监听127.0.0.1。Token、数据库、进程锁文件权限均600。

## 本地测试

先写失败测试，再实现：

- 服务23项：持久幂等、冲突、输入限制、路径、取消、重启不重复提交、HTTP鉴权、Origin拒绝、真实HTTP提交查询取消、资源不足不提交、提交结果不明不重试、远端取消语义、实际 Comfy history格式、可信模板哈希、取消与前置检查竞态、资源等待重启保留、迟到观察不覆盖取消、V3 COMBO模型枚举、有界远端观察、独占进程锁、软链拒绝与GLB校验发布同份数据。
- 转换器11项：真实schema映射、分支折叠、预览透传、参数和路径限制、缺节点/链路/模式/序列检查；用实时导出的 object_info 转换原图为38节点。
- GLB检查8项：内嵌数据、字节/索引/面数、实际顶点和局部包围盒、URI及不支持扩展拒绝、尺寸未标定。
- 合计42项在Mac和DGX均通过、无跳过：`python3 -m unittest discover -s tools/assets -p 'test_*.py'`。实际schema已裁剪为无凭据的仓内fixture，测试不依赖临时文件。

独立审查指出的三项问题均完成红绿回归：远端任务观察最长2小时，超时保留“计算可能继续”且不重提；以无软链文件描述符限长读取到私有临时文件，校验并原子发布同一份字节；恢复任务前先获取root进程独占锁且成功绑定端口，第二实例不会修改第一实例任务。

最后本地/远端代码哈希一致：

| 文件 | SHA-256 |
| --- | --- |
| prop_service.py | b87dc9e39343ba9293538038e6afdb7e4de22f30f3e1a9f87f43294e2ad5f7c5 |
| workflow_adapter.py | 4d9a6c966f22609921fa93357d87f4d667b289c7152a963dcf132df4ebec32d2 |
| glb_inspect.py | 33e277783c12926e400c2cf3e37267d23e79a9c990f25d9d15b2a7ce72a149a1 |

固定生成档位：TRELLIS.2，种子42，上采样1024、重网格256/2次平滑/100万预聚类、目标2万面、纹理/法线1024、AO512×16。下载后的 GLB要求≤32 MiB、≤22000面，必须无外部 URI。

## 授权后首件真实生成

用户明确授权释放旧Comfy模型缓存后，重新核对8188与8190均空队列、原任务仍为`waiting_resources`。只读检查旧`server.py:1192`确认`POST /free`仅设置`unload_models`和`free_memory`队列标记；随后向8188发送这两个布尔值为true，返回HTTP200。未停止或重启旧Comfy、未删除任何模型、未调用全局interrupt，H3检查仍正常。

实际可用内存由约17.9 GiB升至约101 GiB。原任务自动从等待进入运行，没有新建任务或重新提交。Comfy正式执行记录：

- API任务：`d30c33db0665442084444263cecede0e`。
- Comfy任务：`546b1c5e-fa56-4769-a664-2c866f3bacce`。
- `execution_start`: `1788666765286`；`execution_success`: `1788666924025`，推理与后处理共 **158.739秒**。
- `execution_cached.nodes=[]`，本件没有复用节点计算结果。
- 中间形状为6,410,702顶点、12,821,292面；后处理后正式输出为20,000面。
- Comfy进程`MemoryPeak=11575586816`字节，约10.78 GiB，未调整20 GiB上限。结束后GPU利用率回到0%。

正式产物：

| 字段 | 实际值 |
| --- | --- |
| API状态 | completed，reason=null |
| API下载 | `/v1/jobs/d30c33db0665442084444263cecede0e/model.glb` |
| 服务发布文件 | `/home/spark/gmgn-prop-service/data/outputs/d30c33db0665442084444263cecede0e.glb` |
| Comfy原始文件 | `/home/spark/gmgn-prop-service/comfyui/output/props/d30c33db0665442084444263cecede0e_00001.glb` |
| SHA-256 | `b1642a74ee956c4920c884243825b845f4797a48109f8d79ad33ec1cd5bb077b` |
| 字节数 | 1,597,348（约1.52 MiB） |
| 面数 | 20,000三角面 |
| 结构 | 1 primitive，1材质，5 accessor，无场景变换 |
| 贴图 | 3张内嵌PNG：基础色、金属粗糙/AO、法线，无外部URI |
| 局部尺寸 | 1.00789618 × 1.00790071 × 1.00789702模型单位 |
| 局部范围 | min约(-0.50395048,-0.50395131,-0.50394917)，max约(0.50394571,0.50394940,0.50394785) |

目标高度0.3米是用户/测试预设，按Y高度换算尺度约0.297648，尚未应用到GLB。返回`scale_calibrated=false`、`scale_requires_confirmation=true`、`interaction_status=unbound`，没有把图片转网格等同于已可交互物件。

主任务独立核验：通过鉴权 API 下载到 DGX 临时目录，所得 SHA-256 与服务发布值一致；将发布 GLB 复制到 Mac 后，用实际 `glb_inspect.py` 重新检查，文件大小、面数、结构、尺寸及哈希再次一致。没有显示或复制 API 凭据到 Mac。

本地资产位于 `/Users/ghostcorn/dev/gmgnradio/tmp/generated-props/d30c33db0665442084444263cecede0e/blue-block.glb`；同目录 `preview.png` 为真实 GLB 的预览。使用 Blender 5.2 无窗口导入，CPU 两线程、640×640、16采样渲染，约6秒完成；未启动 GMGN 或进行桌面操作。图像检查确认蓝色立方体、完整表面和可见材质，边缘有少量生成起伏。此件只验证服务流程；不能用简单立方体的成功推断复杂家具、活动部件或角色绑定的质量。

## 接入主线所需的下一份证据

真实GLB哈希、面数、材质、模型局部尺寸、API下载与本地预览已验证；仍需主线完成空间物件导入：确认目标尺寸、坐标轴、落地、碰撞和交互绑定。服务返回 `inspect/place`用途候选；`interaction_bindings=[]`和`interaction_status=unbound`明确尚未赋予实际游戏动作。

本轮未触发付费云API；成本为用户DGX计算与模型下载/存储。首件约158.739秒、Comfy进程内存峰值约10.78 GiB，仅代表本次简单积木和固定低档，不能外推复杂物件。Comfy-Org模型页标注MIT，但上线交易前仍需分别核对基础模型、编码器、输入图及输出资产的许可范围。
