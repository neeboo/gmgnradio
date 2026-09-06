# DGX 图片转道具服务验证（2026-09-06）

## 已完成与未完成

已部署独立 Comfy 后端及带鉴权的异步 API，5个模型全部下载完成，并通过实际 API 提交原创参考图。**尚未产出真实 GLB，不能据此宣布道具已能放入空间。**首件被空闲内存门槛阻止，状态可查、可取消；本轮已停止远程轮询，不动旧Comfy缓存。

## 原环境只读检查

- 主机：`dgx_spark` / `spark-836a` / `192.168.1.227`，ARM64，NVIDIA GB10。
- 根盘：3.7 TiB，总剩余约 2 TiB。
- 原 ComfyUI：`8188`，源码 `5599a05`（2026-08-07），队列检查均为空。
- 原 H3：`9000/api/h3/health`返回 `{"status":"ok"}`。
- 原 Comfy 进程 PID `911345`，RSS 约 71,256,024 KiB。整机 121 GiB 内存，约 102—103 GiB 使用，17—18 GiB可用；GPU利用率0%不代表模型已释放。
- 未重启、卸载、升级或停止上述服务；未调用旧 Comfy 释放模型缓存，也未读取其凭据。

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
- 首次返回 `queued`；模型齐全后的最后回读是 `waiting_resources` / `shared_memory_busy`，无假成功、无 GLB链接。
- 幂等键 `original-blue-block-v1`，重复提交复用同任务，不二次调用模型。

最后 `/health` 回读：`status=api_ready`、`generation.ready=false`、`reason=shared_memory_busy`、`available_gib=17.9`、`minimum_gib=24`。API 后续每30秒确认旧、新 Comfy 队列空闲与可用内存，既有单件任务继续排队，不增加新任务。运营者获得用户许可并手工释放旧Comfy驻留缓存，或其他工作负载自然退出后，内存达到门槛即可自动继续；本服务不执行释放。

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

## 接入主线所需的下一份证据

生成成功后需补充真实 GLB 哈希、面数、材质、模型局部尺寸与预览，并将产物交给空间物件导入：确认目标尺寸、坐标轴、落地、碰撞和交互绑定。服务返回 `inspect/place`用途候选；`interaction_bindings=[]`和`interaction_status=unbound`明确尚未赋予实际游戏动作。

本轮未触发付费云API；成本为用户DGX计算与模型下载/存储。还没有真实生成耗时和内存峰值数据。Comfy-Org模型页标注MIT，但上线交易前仍需分别核对基础模型、编码器、输入图及输出资产的许可范围。
