# 图片转道具服务（DGX 原型）

固定采用用户指定的 [Comfy 工作流](https://comfy.org/workflows/920c795f693a-920c795f693a/)，先启用 TRELLIS.2 分支。客户端下载不到任意执行入口，只能提交参考图和道具来源信息。

## 当前部署

- 主机：SSH 配置 `dgx_spark`，ARM64 / GB10。
- 独立目录：`/home/spark/gmgn-prop-service`。
- 原有 ComfyUI `8188`、H3 `9000`保持原状。
- 新 ComfyUI：`127.0.0.1:8190`；新道具 API：`127.0.0.1:8191`。
- ComfyUI 固定提交：`15eb748b3ec5f8a0a2d470b7fb280e2d7579f916`。`v0.33.0`实际缺少模板所需的新核心节点，因此隔离安装当日官方提交。
- 独立 Python 环境复用现有 Torch 的只读安装目录；新增包仅写入独立环境，不升级旧环境。
- 两个新服务由用户级 systemd 管理，API 开机随用户服务启动。停止仅运行 `systemctl --user stop gmgn-prop-api gmgn-prop-comfy`；撤销自动启动运行 `systemctl --user disable gmgn-prop-api`。
- 新 Comfy 进程限制20 GiB内存、禁止使用交换空间；工作流超出此档位将失败，避免无上限挤占其他任务。GPU分配另受Comfy低显存模式和4 GiB保留量约束。

## API

所有请求都需要 `Authorization: Bearer <token>`。Token 只存在服务目录的 `api-token`（0600）；勿提交、截图或打印。浏览器带 `Origin` 的请求被拒绝，不提供跨域权限。

| 方法与路径 | 内容 |
| --- | --- |
| `GET /health` | API 状态与实际生成前置条件，两者分开 |
| `POST /v1/jobs` | 异步提交；必须给 `Idempotency-Key` |
| `GET /v1/jobs/{id}` | 查询状态、来源、产物检查结果 |
| `POST /v1/jobs/{id}/cancel` | 请求取消，JSON `{}` |
| `GET /v1/jobs/{id}/model.glb` | 仅成功且检查通过后下载该任务产物 |

提交体固定为：

```json
{
  "image_base64": "PNG 的 base64 编码",
  "name": "蓝色积木",
  "source": {"license": "CC0-1.0", "author": "参考图作者"},
  "height_meters": 0.3
}
```

PNG 最大 8 MiB、2048×2048；请求体最大 12 MiB；队列最多 8 件、串行执行。仅接受上面四个字段。来源声明指参考图，不能代替模型权重、输出物的商用许可审核。

通过 SSH 在 DGX 调用，无需把 Token 复制到 Mac：

```sh
ssh dgx_spark 'cd /home/spark/gmgn-prop-service && venv/bin/python example_client.py health'
ssh dgx_spark 'cd /home/spark/gmgn-prop-service && venv/bin/python example_client.py submit'
ssh dgx_spark 'cd /home/spark/gmgn-prop-service && venv/bin/python example_client.py status --job <任务ID>'
```

`submit` 使用本仓代码画出的无品牌蓝积木参考图（CC0），固定幂等键，多次调用不会重复生成。其他客户端可通过 `ssh -N -L 18191:127.0.0.1:8191 dgx_spark` 的隧道使用同一 API，需安全配置 Bearer，不对公网开放端口。

## 执行与取消语义

`queued → preflight → waiting_resources / submitting → remote_pending → running → completed / failed`。

- 先检查旧 Comfy 队列、新 Comfy 队列、所需模型和可用内存；至少保留 24 GiB 可用内存才开始首件。资源不足时保持等待，用户能取消。
- 资源等待时每30秒检查一次，不持续调用模型。运营者确认可用内存足够后，已排队任务自动继续；需要释放旧Comfy驻留模型时由用户授权后手工操作，本服务不执行释放。
- 不卸载旧 Comfy 驻留模型、不抢占 H3 任务、不调用全局 `/interrupt`。
- 已在远端运行时，取消返回 `cancel_requested` 与 `compute_may_continue=true`；等待远端结束后丢弃结果。不会谎称计算已经停下。
- 服务重启或提交应答丢失会标为 `interrupted`，不自动重新提交，避免重复消耗计算。
- 尚未提交远端、只在等待资源的任务会在重启后保留队列；进程独占锁和端口绑定均早于恢复任务。远端观察最多2小时，超时标记 `interrupted`，明确远端计算仍可能继续，不重提。
- 当前单机原型未增加多租户账单、租赁市场、外网鉴权网关。

## 道具接入边界

固定低档输出：目标 2 万面、纹理/法线 1024、AO 512×16；采用 GLB 内嵌材质和贴图。产物以不跟随软链的方式限长读取成私有快照，检查文件头、缓冲区、索引、实际顶点、面数和文件哈希，然后原子发布同一份内容；拒绝外部 URI、超预算和不支持的必需扩展。

结果中 `bounds.units=model_units`，`scale_calibrated=false`。参考图无法决定真实尺寸；`height_meters`只作为用户指定的目标尺寸，需经过主线的尺度、地面和碰撞配置后才能放进空间。`affordance_candidates=[inspect,place]`仅为候选用途，`interaction_bindings=[]`、`interaction_status=unbound`，没有虚构咖啡制作或点唱功能。

## 本地验证

```sh
python3 -m unittest discover -s tools/assets -p 'test_*.py'
```

模板转换器按目标 `/object_info` 的 schema 和具名 widget 映射，固定折叠 TRELLIS 分支、去掉预览输出，仅保留正式导出节点 322 的祖先。原始模板随仓保存并固定 SHA-256；仅图片文件名、固定种子及服务自己生成的输出前缀可变。
