# DGX 侧：让生成服务收下「尺寸轴」

日期：2026-10-02　状态：**勘察完成 → 补丁已落盘 DGX 并验证通过**
（落盘时间 2026-10-01 05:56 UTC，服务已重启；完整证据见 §6。）
补丁在 [`docs/plans/2026-10-02-dgx-size-intent.patch`](2026-10-02-dgx-size-intent.patch)，
sha256 `f07f906456d4df8757cabebe50767549304aa9308038e1f4bb19866cb703c0a8`（183 行）。
[`tools/assets/prop_service.py`](../../tools/assets/prop_service.py) 保留的是**落盘前**的基线副本
（仍是 `b87dc9e3…`），与 DGX 上落盘前那份**逐字节相同**，见下面的 sha256。

需求原话：「轴也发过去」。我们这边的尺寸意图（`size_intent {axis, meters, source}`）已经
做完并随任务落盘；这一份解决的是**生成服务那一半** —— 以及勘察时撞到的一个会打断全链路的
兼容性问题。

---

## 0. 三句话结论

1. **服务端严格拒绝未知键**（`prop_service.py:56-59`，`set(data) != allowed` ⇒
   `invalid_fields` / HTTP 400）。所以「客户端加字段、服务端忽略」这条最省事的路**不成立**：
   无条件多发一个键会让现有链路**当场全挂**。
   落地方式因此改成**能力协商**：`/health` 的 `provider` 块里声明了才发，默认不发
   （守护进程侧见 [`services/gmgn-taskd/src/provider.rs`](../../services/gmgn-taskd/src/provider.rs)）。
2. **服务端今天不做任何归一化**，也不存在"按某个轴归一"的现成参数：`ComfyBackend.collect()`
   把 Comfy 导出的 GLB **原样快照发布**，`glb_inspect.inspect_glb()` 只**量**（`scale_calibrated: False`、
   `meters_per_model_unit: None`）。所以**这一步做不到** —— 补丁只做「接受 + 校验 + 原样回显」，
   并在能力声明里**如实写 `applies: "echo"`**，缩放仍由 app 负责。
3. `height_meters` 在服务端**只做三件事**：范围校验（`0.01..3`）、随任务落盘、
   原样回显成 `suggested_height_meters`。它**不**参与任何归一化。所以轴与它的关系只有一条：
   `axis == "height"` 时二者语义相同，数值也必须相同（两侧同一条规则、同一个错误码
   `size_intent_conflict`）。

---

## 1. 最高优先级发现：严格解析未知键

```python
def validate_request(data):
    allowed = {"image_base64", "name", "source", "height_meters"}
    if not isinstance(data, dict) or set(data) != allowed:
        raise APIError("invalid_fields")
```

`submit()` 第一句就是 `validate_request(data)`，错误经 `reply(error.status, {"error": error.code})`
回成 HTTP 400 `{"error":"invalid_fields"}`；守护进程把它映射成 `request_rejected`，
**每一件任务都会失败**。

推论（我们这边的兼容策略就是据此定的）：

- `size_intent` 的发送**必须**由协商决定，默认不发 ⇒ 老服务、老任务、没有意图的提交
  线上字节与今天**逐位相同**。
- 协商**失败一律按"不支持"处理**（fail-closed 的方向是"这一条不发"，不是"提交不发"）。
- 补丁里 `allowed` 的正确写法是「必需键齐 + 未知键为空」，**不能**直接把 `size_intent`
  塞进同一个集合 —— 那样它就成了**必填**，老调用方（四个键）当场全部 400。
  补丁的第一稿就是这么写的，被服务端自己的测试套件抓到了（`invalid_fields` ×18），已修正。

## 2. 勘察事实（只读，ssh `dgx_tailnet`）

源码 sha256（本地 `tools/assets/` 与 DGX 完全一致 ⇒ 补丁可直接照搬）：

```
b87dc9e39343ba9293538038e6afdb7e4de22f30f3e1a9f87f43294e2ad5f7c5  prop_service.py
33e277783c12926e400c2cf3e37267d23e79a9c990f25d9d15b2a7ce72a149a1  glb_inspect.py
4d9a6c966f22609921fa93357d87f4d667b289c7152a963dcf132df4ebec32d2  workflow_adapter.py
```

### 2.1 请求入口与解析

| 位置 | 事实 |
| --- | --- |
| `validate_request()` 56 | 未知键 ⇒ `invalid_fields`（严格） |
| `JobStore.submit()` 117 | metadata 保留除 `image_base64` 外的**全部**键 ⇒ 意图会自动落盘 |
| `JobStore._public()` 109 | 显式列举字段 ⇒ **必须显式加一行**才会回显 |
| `make_server()` 202 | `GET /health` 返回 `{status, generation}`，**勘察当时没有 `provider` 块**（已落盘，现况见 §6.3） |

### 2.2 导出 / 归一化那一步：**不存在**

- 服务里**没有 `to_glb`**，也没有任何 aabb / 朝向 / 归一化代码；
  `workflow_adapter.py` 里 `grep -n "aabb\|normal\|height\|scale\|axis\|longest"` **零命中**。
- `ComfyBackend.collect(job, status, destination)`（448-485）做的是：打开 Comfy 输出的
  `props/<id>_<n>.glb`（不跟随符号链接，读一次到私有快照）→ `inspect_glb(...)`（**只读地量**）
  → `os.replace` 发布 → 拼 `result`。**没有一步改几何**。
- `glb_inspect._inspect_glb()` 返回 `"scale_calibrated": False`、`"meters_per_model_unit": None`、
  `"bounds.space": "mesh_local"`，并且 bounds 直接来自 accessor，**不读节点变换**
  （`scene_transform_count` 只是数一数）。
- 所以「按指定轴归一」在服务端**没有可挂钩的一步**，也没有"按某个轴归一"的现成参数。

### 2.3 `height_meters` 的全部用途

| 行 | 用途 |
| --- | --- |
| 67-69 | 范围校验 `0.01 <= h <= 3`，否则 `invalid_height` |
| 112 | 随任务落盘 / 回显 |
| 482 | `result.suggested_height_meters = job["height_meters"]`（**原样回显，纯建议**） |

它不参与归一化；`result.scale_requires_confirmation = True` 就是服务端在说"缩放由你（app）负责"。

---

## 3. 补丁：接受 + 校验 + 原样回显 + `/health` 声明

[`docs/plans/2026-10-02-dgx-size-intent.patch`](2026-10-02-dgx-size-intent.patch)（183 行，2 个文件）：

1. `validate_request()`：改为「四个必需键齐 + 无未知键」，`size_intent` 是唯一可选键。
2. `validate_size_intent()`：恰好三个键；`axis ∈ {height, longest}`；`source ∈ {user, suggested, default}`；
   `meters` 有限且 `∈ [0.01, 3.0]`；`axis == "height"` 时必须等于 `height_meters`，
   否则 `size_intent_conflict`。不合法一律 `invalid_size_intent`（400）。
3. `_public()`：意图**原样回显**；**没有就不加这个键**（老任务回执逐字节不变）。
4. `GET /health`：新增 `provider` 块 ——
   ```json
   {"id": "gmgn-prop-service", "kind": "remote_http",
    "size_intent": {"axes": ["height", "longest"], "min_meters": 0.01,
                    "max_meters": 3.0, "applies": "echo"}}
   ```
   `applies: "echo"` 是**诚实声明**：本服务不归一，只是收下并回显。写成 `"normalize"`
   会让调用方不再缩放 ⇒ 产物直接错尺寸。
5. `test_prop_service.py`：加两条断言（可选性 + 落盘回显 + 冲突码 + 未知键仍拒；`/health` 声明逐字）。

### ⚠️ 能力字段 `applies` 的含义（边界，勿误读）

`applies: "echo"` 是**对调用方的承诺**，不是随手填的字符串：

- 本服务对 `size_intent` **只做三件事：接受、校验、原样回显**；它**不**按轴归一几何。
- **归一化仍然由 app 负责**。调用方看到 `echo` 就必须自己缩放 ——
  `result.scale_requires_confirmation: true` 与 `suggested_height_meters` 是同一意思的旁证。
- 将来若真在服务端实现顶点级归一，**只需把这个值改成 `"normalize"`**（并同时开始产出
  `authoritative_size`）；**绝不要**在保持 `echo` 字面不变的前提下悄悄改变它的含义 ——
  那会让调用方以为可以不再缩放，产物直接错尺寸。
- 同理，`axes` / `min_meters` / `max_meters` 声明的是**本服务接受的取值范围**，不是"已应用"。

### 应用方式（已由人在 DGX 上实际执行，本仓不代劳）

落盘、测试、重启的完整原话与哈希见 §6，此处只留命令形态：

```bash
# 在 DGX 上（/home/spark/gmgn-prop-service 的 prop_service.py 与 tools/assets/ 落盘前逐字节相同）
cd /home/spark/gmgn-prop-service
git apply -p3 --check   /path/to/2026-10-02-dgx-size-intent.patch   # 先 dry-run
git apply -p3           /path/to/2026-10-02-dgx-size-intent.patch
./venv/bin/python test_prop_service.py                              # 25 OK（该目录没有 pytest）

# 或者在本仓里对着源码副本 dry-run（路径是 tools/assets/…）
git apply -p1 --check docs/plans/2026-10-02-dgx-size-intent.patch
```

### 本地验证（补丁后）

```
python3 -m unittest test_prop_service        # 补丁前：Ran 23 tests ... OK
python3 -m unittest test_prop_service        # 补丁后：Ran 25 tests ... OK（含 2 条新增）
```

真机（DGX venv）复跑同一套：**Ran 25 tests … OK**，见 §6.2。

## 4. 「能不能真的按轴归一」：**这一步做不到**，以及为什么不是个小补丁

服务端今天什么都不归一，所以"用它决定归一化轴"必须**新增**一步。可行的形态只有两类：

| 形态 | 可行性 |
| --- | --- |
| 把轴塞进 Comfy 工作流 | **不行**。`workflow.source.json` 的 sha256 是硬校验（`untrusted_workflow`），而且工作流里根本没有"按某轴归一"这种参数（TRELLIS 出的是网格，不是尺寸） |
| 在 `collect()` 里重写 GLB | 可行，但**不是**改一行：`inspect_glb` 的 bounds 来自 accessor 且**不读节点变换**，所以 |
| ├ 只改根节点 `scale` | **错**。`inspection.bounds` 不会变 ⇒ app 量到的与 `authoritative_size` 不一致，正是我们要消灭的第二份真相 |
| └ 直接改 POSITION 的 accessor `min/max` 与二进制 chunk（或整块重编 GLB） | 正确，需自带一套 GLB 读写与新的测试（`test_glb_inspect.py` 那一套不够），并且**必须同时**产出 `authoritative_size`（那才有米标定）。这是一件独立的工作项，不该混进这次的"接受并回显"里 |

所以本次补丁**只接受并回显**，`applies` 写 `echo`，缩放继续由 app 按意图做
（`WorldPropLayout.effectiveSize`：手动 > 意图 > 权威 > 自动推断）。
等哪天真的做了顶点级归一，改的是**能力声明的值**（`echo` → `normalize`）+ 发
`authoritative_size`，而不是悄悄换掉同一个字段的含义。

## 5. 需要跨端确认 / 尚未做的事

- 落盘前状态：**未动 DGX 一个字节**（补丁只以 diff 交付）。**现已落盘**，见 §6。
- **真机确认清单**（逐条实测结果）：
  1. ✅ `/health` 已看到 `provider.size_intent` —— 原话见 §6.3；
  2. ⬜ 守护进程 `provider_probe` 回给 app 的 `capabilities.size_intent` 应与上面一致
     （app 据此能看见"这台服务只回显、不归一"）—— **本次未验**，待守护进程侧接上后再跑；
  3. ✅ 带意图提交一次，`GET /v1/jobs/<id>` 原样回显 `size_intent`（§6.4）；
  4. ✅ 故意发未知键 `size_axis` 仍 400 `invalid_fields` —— "协商才发"这条纪律没有被放宽。
- **只改了这两个文件**：`prop_service.py`、`test_prop_service.py`（外加两个 `.bak`）。
  ComfyUI、模型、权重、其它服务均未触碰（`gmgn-prop-comfy.service` MainPID 全程不变）。
- **回退**：见 §6.5；老调用方四键请求在新旧两版服务上都成立。

---

## 6. 落盘与验证（2026-10-01 05:56 UTC，`dgx_tailnet`）

状态：**已落盘、已实测、服务已重启**。以下是实测原话（最短形式）。

### 6.1 落盘事实与哈希

| 项 | 值 |
| --- | --- |
| 补丁 sha256 | `f07f906456d4df8757cabebe50767549304aa9308038e1f4bb19866cb703c0a8`（183 行，scp 前后一致） |
| 落盘前 `prop_service.py` | `b87dc9e39343ba9293538038e6afdb7e4de22f30f3e1a9f87f43294e2ad5f7c5` |
| 落盘前 `test_prop_service.py` | `f0228fbcf6478f5a443a8c217bcc6b19b08003762fd7a3ce4078c353e60e5411` |
| **落盘后** `prop_service.py` | `d62f3d4a18d81113c4c1dccd3d04519b864cf369a649db6097e86c65d06bb869` |
| **落盘后** `test_prop_service.py` | `67aded8c88d82d0a35c5e39d1aab81911edf78a38078cf7ccadf28ff9457757f` |

```
$ git apply -p3 --check -v /tmp/gmgn-size-intent.patch
Checking patch prop_service.py...
Checking patch test_prop_service.py...
DRYRUN_EXIT=0
$ git apply -p3 -v /tmp/gmgn-size-intent.patch
Applied patch prop_service.py cleanly.
Applied patch test_prop_service.py cleanly.
APPLY_EXIT=0
$ git apply -p3 -R --check /tmp/gmgn-size-intent.patch   # 反向干跑
REVERSE_CHECK_EXIT=0                                      # ⇒ 可干净回撤
```

注：`/home/spark/gmgn-prop-service` **不是 git 仓库**，`git apply` 在此只当纯文件工具用。
本仓 [`tools/assets/prop_service.py`](../../tools/assets/prop_service.py) 是**落盘前**的基线副本
（仍是 `b87dc9e3…`），未随 DGX 一起更新。

### 6.2 服务端测试：**25 OK**

该目录**没有 pytest**，本来跑法就是 `unittest.main()`；用其自带 venv 实测：

```
$ ./venv/bin/python test_prop_service.py
.........................
----------------------------------------------------------------------
Ran 25 tests in 1.611s

OK
```

补丁前 23，新增 2 条 ⇒ **25 OK**。

### 6.3 重启方式与 `/health` 新原文

服务由 **systemd `--user`** 单元 `/home/spark/.config/systemd/user/gmgn-prop-api.service` 拉起
（不是 nohup、也不是 supervisor）。重启沿用**它原本的方式**，未引入新的进程管理：

```
$ systemctl --user restart gmgn-prop-api.service     # MainPID 2463 → 91771，active/running
```

`GET /health`（带 `Authorization: Bearer $(cat api-token)`）新原文：

```json
{"status": "api_ready", "provider": {"id": "gmgn-prop-service", "kind": "remote_http", "size_intent": {"axes": ["height", "longest"], "min_meters": 0.01, "max_meters": 3.0, "applies": "echo"}}, "generation": {"ready": false, "reason": "shared_memory_busy", "available_gib": 21.5, "minimum_gib": 24}}
```

`provider.size_intent` 已出现，**`applies: "echo"`**（含义边界见 §3 的 ⚠️ 小节）。

### 6.4 端到端：**零 GPU 代价**

落盘时 `generation.ready=false`（`shared_memory_busy`，21.4 < 24 GiB）。worker 在
`preflight` / `waiting_resources` 会调 `readiness()` 并停在原地，**根本不向 ComfyUI 提交**，
所以走的是「提交 → 读回显 → 立刻 cancel」，**没跑生成、没产出 GLB、GPU 全程 0%**：

```
202 Accepted  {"id":"6b47988e822f418689918d6dbcfde12d","state":"queued", … ,"size_intent":{"axis":"longest","meters":1.1,"source":"user"}}
GET /v1/jobs/6b47988e…  200  "state":"waiting_resources", "reason":"shared_memory_busy",
                             "size_intent":{"axis":"longest","meters":1.1,"source":"user"}   ← 原样回显
未知键 size_axis                     → 400 {"error": "invalid_fields"}
axis=height 且 meters≠height_meters  → 400 {"error": "size_intent_conflict"}
DB row: {'state': 'cancelled', 'prompt_id': None, 'reason': 'shared_memory_busy'}   ← prompt_id=None ⇒ ComfyUI 从未被调用
nvidia-smi: 0 %（前后一致）
```

**边界**：本次覆盖的是真实 HTTP 面上的「回显 + 严格校验」，**不是**端到端产出 GLB。
要跑一次真产物，需等显存空出（≥ 24 GiB）并接受一次完整生成耗时。

### 6.5 回滚

```bash
ssh dgx_tailnet 'export XDG_RUNTIME_DIR=/run/user/1000
cd /home/spark/gmgn-prop-service
cp -p prop_service.py.bak-20261001T055646Z prop_service.py
cp -p test_prop_service.py.bak-20261001T055646Z test_prop_service.py
rm -rf __pycache__
systemctl --user restart gmgn-prop-api.service
sleep 2; curl -s -H "Authorization: Bearer $(cat api-token)" http://127.0.0.1:8191/health'
```

备份文件名固定为 `prop_service.py.bak-20261001T055646Z` /
`test_prop_service.py.bak-20261001T055646Z`（sha256 与落盘前原文件逐一相符）。
回滚后 `/health` 应回到
`{"status": "api_ready", "generation": {"ready": false, "reason": "shared_memory_busy", …}}`，
**无 `provider` 键**。等价替代：`git apply -p3 -R /tmp/gmgn-size-intent.patch`（补丁仍留在 DGX `/tmp`）。
