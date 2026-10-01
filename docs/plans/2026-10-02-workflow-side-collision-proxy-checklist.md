# 工作流侧清单：让生成产物自带碰撞代理与权威尺寸

日期：2026-10-02　状态：**只写文档，未动 DGX**（用户明确说过不要动 DGX；等他说做再做）

这一份是「让生成工作流自带的碰撞数据被真正用起来」的**工作流那一半**。app + 守护进程
那一半已经落地（见本文末尾的「接收端现状」）。这里写的是 DGX 上那套 prop service
需要加什么，写成可以照着做的清单。

对象的源码就在本仓：`tools/assets/`（DGX 上部署在 `/home/spark/gmgn-prop-service`，
`gmgn-prop-api.service` / `gmgn-prop-comfy.service`）。所以下面每一条都能指到具体函数。

---

## 0. 先看清楚一件事：现在的 `inspection` 不能当尺寸用

`tools/assets/glb_inspect.py` 的 `_inspect_glb()` 末尾返回：

```python
"bounds":{"min":lower,"max":upper,"dimensions":[b-a for a,b in zip(lower,upper)],
          "units":"model_units", "space":"mesh_local"},
"scale_calibrated":False, "meters_per_model_unit":None,
```

也就是**模型单位、网格局部空间、未标定**。app 今天只能自己把网格缩放到请求高度再量一次
（`ResidentPropRenderer.prepare` 的 `sourceHeight = maximum.y - minimum.y`），于是：

- 换一个生成后端 ⇒ 轮廓不同 ⇒ 碰撞不同；
- 薄/凹/细长的物件（斧头、长剑）用"尺寸 × 朝向"的偏航盒子表示 ⇒ **要么挡空气、要么漏**。

这正是要修的东西。注意两条路要分开：

| 要给的东西 | 需不需要米标定 | 说明 |
| --- | --- | --- |
| 碰撞代理 `collider.glb` | **不需要** | 归一化是**尺度无关**的：只要拿自己的包围盒把网格归零、居中、高度归一到 1 即可 |
| 权威尺寸 `authoritative_size` | **需要** | 说"这东西 0.42 m 高"就必须真的知道米。标定不了就**不要发这个字段**（app 会照旧自己量） |

**所以第 1 步（碰撞代理）可以立刻做，第 2 步（权威尺寸）要先解决标定。** 这是这份清单最
重要的一条判断：把不确定的东西说成权威，比不说更坏。

---

## 1. 在哪一步导出碰撞代理

落在 `tools/assets/prop_service.py` 的 `ComfyBackend.collect()`（约 448–486 行）。它现在是：

1. 打开 Comfy 输出的 `props/<job_id>_<n>.glb`（不跟随符号链接，读一次到私有快照）；
2. `inspect_glb(temporary, max_bytes=32MiB, max_triangles=22000)`；
3. `os.replace(temporary, destination)` 发布 `model.glb`；
4. 返回 `result` 字典。

在 **2 与 3 之间**（校验通过之后、发布之前）插入一步 `export_collision_proxy(...)`。
放这里的三个理由：

- 此刻拿到的是**已校验、已快照**的字节，与 `inspection` 描述的是同一份数据；
- 代理与模型必须**成对发布**：只发布模型会让世界拿到"看起来 ready、其实没有碰撞数据"
  的产物（守护进程那一侧已经把这件事做成要么全成、要么整个任务 `interrupted`）；
- 它是纯 CPU、无 GPU 的一步，失败不会浪费已花的生成算力。

### 1.1 工具与算法

新增 `tools/assets/collision_proxy.py`，用 **trimesh**（DGX 的 Comfy 环境里已经有它，
`download_models.py` 走的就是同一套依赖）：

```python
import trimesh

def export_collision_proxy(source: "trimesh.Trimesh", *, target_faces: int,
                           hull: bool) -> "trimesh.Trimesh":
    # 1) 合并同位置的重复顶点：Comfy/TRELLIS 导出的 GLB 常常每个三角形独立顶点，
    #    不合并的话凸包完全没有意义（每个面都是孤立的）。
    source.merge_vertices()
    # 2) 去掉退化面与重复面，否则凸包会因为零面积三角形报错。
    source.update_faces(source.nondegenerate_faces())
    source.update_faces(source.unique_faces())
    if hull:
        proxy = source.convex_hull          # 凸包：面数少、保证凸（app 可以用凸的快速路径）
    else:
        proxy = source.simplify_quadric_decimation(face_count=target_faces)  # 降面
    proxy.remove_degenerate_faces()
    return proxy

def normalize(proxy: "trimesh.Trimesh") -> "trimesh.Trimesh":
    # 契约要求的归一化：底面 y=0、顶面 y=1、X/Z 以自身 AABB 居中。
    # 尺度无关 —— 不需要知道米。
    lo, hi = proxy.bounds
    height = float(hi[1] - lo[1])
    if not (height > 0):
        raise ValueError("collision_proxy_degenerate")
    center_x = float((lo[0] + hi[0]) / 2)
    center_z = float((lo[2] + hi[2]) / 2)
    proxy.apply_translation([-center_x, -lo[1], -center_z])
    proxy.apply_scale(1.0 / height)
    return proxy
```

**用哪个？** 两个都做，按物件形状选：

- `glb-hull`（凸包）：默认。面数最少（几十到几百），凸 ⇒ 碰撞测试最便宜，而且**不会漏**
  （凸包包含原网格）。对绝大多数"实心块状"道具（咖啡机、杯子、积木）就是正确答案。
- `glb-decimated`（降面）：只有凹形/空心物件（椅子、拱门、环形摆件）才需要，因为凸包会把
  凹处填掉 ⇒ 又变成"挡空气"。降面必须配一条**凹性检查**（见 §1.3）。

两个都用**同一组参数**（`target_faces`、`hull`），参数进 `workflow_profile`（见 §3）。

### 1.2 导出什么格式与命名

- 格式：**GLB v2，二进制 chunk，三角形图元（mode=4），POSITION 用 float32 VEC3**。
  与 `model.glb` 完全同一种容器 —— app 用**同一个** `GLBColliderDecoder` 解，不需要第二个解析器。
  *不要*导出 OBJ/PLY/STL：那会引入第二个加载器，也就是第二套几何。
- 命名：`<job_id>.collider.glb`，与 `<job_id>.glb` 并排放在同一个私有目录。
- 尺寸上限（守护进程契约，硬性）：**≤ 4 MiB**、**≤ 4096 个三角形**。
  凸包通常在 4 KiB–64 KiB / 100–600 面，离上限很远。若超限，先降 `target_faces`
  再重试一次；仍然超限就**不发 `collision_*` 字段**（app 会退回盒子）并把这个事实
  写进任务日志 —— 不要发一个超限的代理让 app 拒收。
- 材质/贴图/法线一律不带：代理只有几何。

### 1.3 凹性检查（只在 `glb-decimated` 分支）

降面可能把凹处也抹平。一条便宜的检查：对代理做 `convex_hull`，比较体积/表面积。

```python
def concavity(proxy, hull):
    # 0 = 完全凸。经验阈值 0.02：凹掉的体积不到 2% 就当作凸，发 hull 更划算。
    return max(0.0, (hull.volume - proxy.volume) / max(hull.volume, 1e-9))
```

`concavity(decimated, decimated.convex_hull) < 0.02` ⇒ 改发 `glb-hull`。
否则发 `glb-decimated`。把这个比值写进任务日志，方便以后调阈值。

---

## 2. 回执里新增哪些字段

在 `collect()` 返回的 `result` 里**平铺**加五个字段（与既有的 `model_url` 同一风格）：

```python
collision = export_collision_proxy(...)          # 返回 (bytes, sha256, triangles, format) 或 None
if collision is not None:
    result["collision_url"]       = f"/v1/jobs/{job['id']}/collider.glb"
    result["collision_format"]    = "glb-hull" | "glb-decimated"
    result["collision_sha256"]    = hashlib.sha256(data).hexdigest()
    result["collision_bytes"]     = len(data)
    result["collision_triangles"] = triangle_count
```

权威尺寸（**只有标定得了才加**）：

```python
result["authoritative_size"] = {
    "dimensions": [dx, dy, dz],   # 米，与 up_axis/forward_axis 同一坐标系
    "units": "m",
    "up_axis": "+Y",
    "forward_axis": "-Z",
}
```

### 2.1 与守护进程契约逐字对齐（`services/gmgn-taskd/src/model.rs`）

| 字段 | 类型 | 约束 | 守护进程错误码 |
| --- | --- | --- | --- |
| `collision_url` | string | 必须**恰好**是 `/v1/jobs/<远端 id>/collider.glb` | `unsafe_download` |
| `collision_format` | string | `glb-hull` 或 `glb-decimated` | `invalid_collision_descriptor` |
| `collision_sha256` | string | 64 位十六进制 | `invalid_collision_descriptor` |
| `collision_bytes` | integer | `1 ..= 4*1024*1024` | `invalid_collision_descriptor` |
| `collision_triangles` | integer | `1 ..= 4096` | `invalid_collision_descriptor` |
| `authoritative_size.dimensions` | 3 个 number | 每个 `> 0`、`<= 100`、有限 | `invalid_authoritative_size` |
| `authoritative_size.units` | string | 只接受 `"m"` | `invalid_authoritative_size` |
| `authoritative_size.up_axis` | string | `+Y` / `-Y` | `invalid_authoritative_size` |
| `authoritative_size.forward_axis` | string | `+Z` / `-Z` / `+X` / `-X` | `invalid_authoritative_size` |

三条**必须遵守**的语义：

1. **五个 `collision_*` 要么全在、要么全缺。** 部分出现是自相矛盾的描述（有 URL 没摘要
   就无法核验），守护进程会报 `invalid_collision_descriptor`。`null` 与"键不存在"等价。
2. `authoritative_size` 要么整块不存在，要么**恰好四个键**（多一个未知键就拒收）。
3. **不合法就整体不发，不要发一个"差不多"的值。** 守护进程对任何一个不合法字段都是
   **硬失败**（任务 `interrupted` + 可读错误码），不是静默忽略 —— 静默忽略会让碰撞形状
   在用户不知情下从代理退回盒子。

### 2.2 GLB 与 sha256/bytes 必须自洽

守护进程的核验口径与 `model.glb` **逐字相同**（`model::validate_collider_glb`）：

- `data[:4] == b"glTF"`、`version == 2`、声明的总长度 `== len(data)`；
- `len(data) == collision_bytes`；
- `hashlib.sha256(data).hexdigest() == collision_sha256`。

所以 `collision_sha256` / `collision_bytes` 必须是**最终写进 `collider.glb` 的那些字节**的
摘要与长度 —— 先 `fsync` 落盘、再算摘要，不要对内存里的中间态算。

`collision_triangles` 用与 `glb_inspect.py` 里 `triangles += count // 3` **同一个算法**数，
保证服务自报的三角形数与 app 实际解出来的数量一致（app 侧还会再数一次并卡 4096 上限）。

### 2.3 服务端要加的东西

1. `GET /v1/jobs/{id}/collider.glb`：与 `model.glb` 那条**同一实现**（`make_server()` 的
   `handle_request`，约 213 行，`Content-Type: model/gltf-binary`），同样只允许成功且检查
   通过的任务下载，同样禁符号链接、同样给 `Content-Length`。
2. `tools/assets/test_prop_service.py` / `test_glb_inspect.py` 里加断言：
   - 有代理时回执五个字段全在、且 `sha256/bytes` 与下载到的字节一致；
   - 故意把 `collision_bytes` 改一个字节 ⇒ 下载被拒；
   - 无代理时回执里**一个字都不出现** `collision_`；
   - `authoritative_size` 的四键与类型。
3. `tools/assets/README.md` 的 API 表里加一行 `GET /v1/jobs/{id}/collider.glb`。

---

## 3. 跨后端一致（CUDA / MLX / 云端）

不一致的根源有两个，要分别治：

1. **网格轮廓不同**（不同后端/不同模型版本给出的网格不一样）；
2. **代理导出参数不同**（同一网格，一次凸包一次降面 ⇒ 两种碰撞）。

第 1 个治不了也不该治 —— 那本来就是这个后端生成的东西。第 2 个必须治。

做法：把**决定代理轮廓的每一个参数**写进 `workflow_profile` 指纹，并让所有后端用同一组
默认值。现在 `collect()` 里是硬编码的：

```python
"workflow_profile": "trellis2-prop-low-v1"
```

改成与守护进程 `model.rs::GenerationProfile::fingerprint()` **同一种格式**：

```
gmgn-mesh-v1;resolution=<n>;decimation=<n>;texture_size=<n>;remesh=<bool>;collision=glb-hull;collision_faces=<n>
```

- 前四段守护进程已经在用（`resolution` 64–4096、`decimation` 1000–5,000,000、
  `texture_size` 64–8192、`remesh` bool）；**多出来的两段是新加的**，所以配套要改
  `model.rs` 的 `PROFILE_TAG`/`GenerationProfile::parse`（属于接收端改动，见 §6 待办）。
- 在加进指纹之前，**先把当前这个不一致修掉**：`trellis2-prop-low-v1` 不是
  `GenerationProfile::parse` 认得的格式，于是 `failover`（换后端重开同一件产物）会直接
  报 `invalid_workflow_profile`。这是既有的一个坑，值得顺手修。

参数统一：`collision` 与 `collision_faces` 的默认值放在**一处**（比如
`collision_proxy.py` 里的 `DEFAULT_POLICY`），CUDA/MLX/云端三个后端都从那里读，禁止各自
写死。这样"同一张图 + 同一个指纹 ⇒ 同一份代理"，而指纹就在回执里，可审计、可比对。

顺带：`workflow_adapter.py::build_prompt()` 现在按 `object_info` 解析工作流输入。
代理导出在 Comfy **之外**（`collect()` 里），所以它天然与运行后端无关 —— 这是好事，
要在 README 里写清楚，免得以后有人把它挪进某个后端的 custom node。

---

## 4. 旧资产怎么办

**不回填。** 理由：

- 老产物只有 `model.glb`，没有原始的未降面网格，也没有当初的生成参数；事后重算代理
  等于用一个今天才知道的算法去描述一件昨天生成的东西 —— 那是**第三种**几何，比"没有代理"
  更坏。
- 接收端已经保证了缺失时的行为与今天**逐字节一致**：没有 `collision_*` ⇒ app 用今天的
  偏航盒子。所以老资产不会因为这次改动而变差。
- 真要让某件老资产用上代理，走**重新生成**（`failover` 或重新许愿），而不是回填。

一个可选的小动作：把老资产的 `inspection` 里已有的 `bounds.dimensions` 作为
`authoritative_size` 回填 —— **不要做**，因为它是 `model_units` 且 `scale_calibrated:false`
（见 §0），拿它当米用是错的。

---

## 5. 验收怎么做（工作流侧）

在 DGX 上（等用户批准后再做）：

```sh
# 单元：代理导出本身
venv/bin/python -m unittest tools/assets/test_glb_inspect.py tools/assets/test_prop_service.py -v
# 端到端：提交→回执→把 collider.glb 拉下来自己核验 sha256/bytes/三角形数
ssh dgx_spark 'cd /home/spark/gmgn-prop-service && venv/bin/python example_client.py submit'
```

四条必须实测的断言（缺一条都说明这条链没通）：

1. 回执里五个 `collision_*` 全在，且**下载到的字节**的 sha256/长度与回执逐位一致；
2. 把 `collider.glb` 下载下来，用与 app 同一个 `GLBColliderDecoder` 解出的三角形数 ==
   回执的 `collision_triangles`；
3. 把回执里 `collision_bytes` 改一个字节 ⇒ 守护进程拒绝（`collision_integrity_failed`）；
4. 同一张图跑两个后端（CUDA / MLX）⇒ `workflow_profile` 相同 ⇒ `collider.glb` 的
   `collision_sha256` 相同。

---

## 6. 接收端现状（这一半已经做完，供工作流侧对照）

**契约（`services/gmgn-taskd/`）**

- `src/model.rs`：`COLLIDER_LIMIT = 4 MiB`、`COLLIDER_TRIANGLE_LIMIT = 4096`、
  `COLLISION_FORMATS`、`AUTHORITATIVE_SIZE_UNITS = "m"`、`UP_AXES`、`FORWARD_AXES`；
  `collision_descriptor()` / `authoritative_size()` / `declares_collision()` /
  `validate_collider_glb()`；`receipt()` 里对两块做严格校验（缺失 ⇒ `Ok(None)` 且行为不变）。
- `src/provider.rs`：`download_collision()`（路径钉死在同一 origin 的固定任务路径、禁重定向、
  按 `collision_sha256`/`collision_bytes` 核验）；`PropProvider::fetch_collision`（默认实现
  是**可见拒绝** `collision_not_supported`，不是静默"没有代理"）。
- `src/daemon.rs`：`fetch_artifact()` 先把模型与代理**都取完核验完**，再一起落盘；
  代理取不到 ⇒ 整个任务 `interrupted` + 可读错误码，不留半个产物。
- `src/store.rs`：重启恢复时两样都重新核验，任一对不上就两样一起清掉。
- 新增字段：`job.local_collision_path`（`Option`，缺失时序列化里不出现 ⇒ 旧客户端逐字节不变）。

**app 侧（`apps/macos/Packages/WorldRuntime/`）**

- `WorldPropCollisionProxy.swift`（新）：代理描述、权威尺寸、尺寸来源、归一化代理网格
  （安装时校验底面 y=0 / 顶面 y=1 / XZ 居中）、`WorldPropObstacle`、代理注册表
  （按 sha256 寻址）、`WorldPropObstacleOverlap`，以及
  `WorldCapsuleClearance.isClear(_:at:of: WorldPropObstacle)` —— **唯一一条**判定通路的入口。
- `WorldPropLayout.swift`：`WorldGeneratedProp` 新增可选 `collision` / `authoritativeSize`、
  `effectiveSize`（有权威尺寸就以它为准）、`sizeSource`（审计）、`generatedCollisionObstacle`；
  `WorldLayoutObstacles.Resolution` 新增权威的 `obstacles`，`volumes` 变成"只认盒子的旧消费者"
  的**保守**投影（只会多挡、不会漏挡）。
- `CollisionVolumeWorld.swift` / `WorldPlacementRouteGuard.swift` / `PropPlacementEvaluator.swift`：
  三个消费者都改成读 `obstacles`，形状分派只发生在 `WorldCapsuleClearance` 里。
- `TriangleMeshCollisionWorld.swift`：`segmentTriangleDistanceSquared` 从 `private` 放开为
  模块内可见，让代理碰撞复用**同一份**三角形距离原语（不是第二套几何）。

**还差一点串行的接线**（这三个文件正被另外三条线改，按约定没有动；等它们落地后按下面的
最小改动接上即可）：

行号会随其它三条线漂移，所以下面按**符号/锚点**定位（`grep` 就能找到）：

| 文件 | 锚点（grep 用） | 改动 |
| --- | --- | --- |
| `App/GMGNRadioApp.swift` | `let prop = WorldGeneratedProp(objectID: job.objectID` | 从回执里读 `collision_*` / `authoritative_size` 传进 `WorldGeneratedProp`；若 `record.localCollisionPath` 存在则 `WorldPropCollisionProxyStore.shared.install(decoding:sha256:)` |
| 同上 | `residentPropGridEditor.updateHover(` | 加 `placedObstacles: WorldLayoutObstacles.resolve(context.state).obstacles` |
| `Presence/ResidentPropPlacementService.swift` | `var placed: [(String, WorldObjectState, WorldCollisionVolume)] = obstacles.volumes` | `obstacles.volumes` → `obstacles.obstacles`（并把元组里的类型换成 `WorldPropObstacle`）；`blockedNodes(volume:)` → `blockedNodes(obstacle:)`；`CollisionVolumeWorld(volumes:)` → `CollisionVolumeWorld(obstacles:)`；`PropPlacementEvaluator.evaluate(..., placedObstacles:)` |
| 同上 | `let footprint = WorldPlanarFootprint(size: SIMD2(prop.size.x, prop.size.z)` | `prop.size` → `prop.effectiveSize`（footprint 也要以权威尺寸为准） |
| `Presence/ResidentPropGridEditorModel.swift` | `func updateHover(` 与它的 `placedProps:` 参数 | 加一个 `placedObstacles: [WorldPropObstacle]? = nil` 入参，转交 `PropPlacementEvaluator.evaluate(placedObstacles:)` |
| `Presence/PropGenerationStore.swift` | `var localModelPath: String?` | 加 `var localCollisionPath: String?`（镜像守护进程的新字段） |
| `Presence/PropGenerationClient.swift` | `struct PropGenerationResult` | 加可选 `collision_url` / `collision_format` / `collision_sha256` / `collision_bytes` / `collision_triangles` / `authoritative_size` 的 `CodingKeys` 映射 |

> 交接前的**安全网**：`Resolution.volumes` 不是"旧的错几何"，而是代理的**保守** yaw OBB
> （只会多挡、不会漏挡，有断言 `theLegacyBoxProjectionNeverUnderBlocksTheProxy` 与 harness
> 的 `viaProxy ⊆ viaBox` 锁着）。所以在这三处接线之前，系统是"安全但会假拒绝细长物件"，
> 不是 fail-open。

**待办（接收端）**：把 `collision=…;collision_faces=…` 两段加进
`model.rs::GenerationProfile::fingerprint()` 与 `parse()`，这样 §3 的跨后端指纹才完整。
这一步要等 `workflow_profile` 的实际格式先与服务端对齐（现在服务端发的是
`trellis2-prop-low-v1`，不是 `gmgn-mesh-v1;…`，见 §3）。

---

## 7. 可直接粘贴的补丁说明（第 1 / 2 / 5 项，等信号后一次落地）

**这三项必须作为一次原子改动落地。** 原因：`ResidentPropPlacementService`（第 3 项）
已经改用 `WorldLayoutObstacles.resolve(...).obstacles`，而摆放格子的着色那条路
（`ResidentPropGridEditorModel` → `PropPlacementEvaluator`）如果还在传保守盒子，那么
**只要有任意一件物件带代理，格子说"可放"与服务接受就会不一致** —— 那正是
`tools/test-resident-prop-one-judge.swift` 用 4244 条断言锁死的东西。
（现在还没落地，是因为第 1 项没落地 ⇒ 没有任何物件带 `collision` ⇒ 分歧不可观测。）

### 7.1 `Presence/ResidentPropGridEditorModel.swift`（第 5 项）

`func updateHover(` 的签名里，`placedProps: [WorldCollisionVolume]` 那一行后面加一个可选入参，
并在它调用 `PropPlacementEvaluator.evaluate(` 的地方把它传下去：

```swift
    func updateHover(
        normalizedCursor: SIMD2<Float>,
        inverseViewProjection: simd_float4x4,
        footprintSize: SIMD2<Float>,
        height: Float,
        objectID: String,
        blockingVolumes: [WorldCollisionVolume],
        placedProps: [WorldCollisionVolume],
        placedObstacles: [WorldPropObstacle]? = nil,     // ← 新增
        ...
    ) {
```

在它内部的 `PropPlacementEvaluator.evaluate(` 调用里加一行：

```swift
                placedProps: placedProps,
                placedObstacles: placedObstacles,        // ← 新增
```

`placedObstacles` 为 nil 时 `evaluate` 会把 `placedProps` 当盒子用（与今天逐字一致）。

### 7.2 `App/GMGNRadioApp.swift` 的 `updateHover` 调用点（第 2 项）

`residentPropGridEditor.updateHover(` 那个调用里，把

```swift
            blockingVolumes: context.manifest.collisionVolumes.filter(\.isBlocking),
            placedProps: context.state.objectStates.values.compactMap(\.generatedCollisionVolume)
```

改成

```swift
            blockingVolumes: context.manifest.collisionVolumes.filter(\.isBlocking),
            placedProps: [],
            placedObstacles: WorldLayoutObstacles.resolve(context.state).obstacles
```

（`placedProps: []` 与摆放服务那侧同形：权威输入是 `placedObstacles`，盒子入口留空。
`WorldPropObstacle` 与 `WorldLayoutObstacles` 都由 `import WorldRuntime` 带进来，
这个文件已经 import 了。）

### 7.3 `App/GMGNRadioApp.swift` 的物件登记处（第 1 项）

锚点是这四行（`prepareResidentProp` 之后构造 `WorldGeneratedProp` 的地方）：

```swift
                let prop = WorldGeneratedProp(objectID: job.objectID, sourceWishID: job.id.uuidString,
                    assetID: descriptor.assetID, displayName: job.name,
                    size: .init(x: prepared.size.x, y: prepared.size.y, z: prepared.size.z), sourceHeight: prepared.sourceHeight)
```

改成：

```swift
                // 生成工作流自带的碰撞数据：解代理 + 记权威尺寸。两块都是**可选**的，
                // 缺失时这一段与改造前逐字节一致（size 仍然是 measured 那一份）。
                if let path = record.localCollisionPath, let collision = receipt.result?.workflowCollision {
                    // 解不出来就**不安装**：`WorldGeneratedProp.isValid` 会因为"声明了代理"
                    // 而把整件物件判无效 ⇒ 落到 `unmodelledPlacedProp` 的可见拒绝。
                    // 这里刻意不看返回值 —— fail-closed 由那条既有规则负责，不在这里各写一份。
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
                        WorldPropCollisionProxyStore.shared.install(decoding: data, sha256: collision.sha256)
                    }
                }
                let prop = WorldGeneratedProp(objectID: job.objectID, sourceWishID: job.id.uuidString,
                    assetID: descriptor.assetID, displayName: job.name,
                    size: .init(x: prepared.size.x, y: prepared.size.y, z: prepared.size.z), sourceHeight: prepared.sourceHeight,
                    collision: receipt.result?.workflowCollision,
                    authoritativeSize: receipt.result?.workflowAuthoritativeSize)
```

要点：

- `receipt` 已经在这个作用域里（上面那行 `guard let receipt = record.receipt` 拿到的），
  `receipt.result?.workflowCollision` / `workflowAuthoritativeSize` 是
  `Presence/PropGenerationWorkflowCollision.swift`（第 4 项顺手新增的换算文件，已落地）
  上的属性。若想显式区分"没声明"与"声明了但非法"，用同文件里的
  `receipt.result?.declaresWorkflowCollision`：
  `declares == true && workflowCollision == nil` 时应当**可见拒绝**，而不是静默退回盒子。
- `descriptor.assetID` 是 `"sha256:" + inspection.sha256`；**不要**拿它当代理的摘要 ——
  代理的摘要是 `collision.sha256`（`install(decoding:sha256:)` 已经这么用了）。
- 已存在物件的比较（`guard existing.generatedProp == prop`）会自动把 `collision` /
  `authoritativeSize` 一起比进去（`WorldGeneratedProp: Equatable`）；同一件产物的回执是
  确定的，所以两次准备得到同一份 `prop`。若担心某后端在两次回执里给出不同摘要，把它改成
  `existing.generatedProp?.matchesIdentity(of: prop) == true` 即可（那个函数已经存在）。
