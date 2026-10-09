# 冷启动到就绪：真机时间线（改前 / 改后）

2026-10-09 · 证据全部只读取得，没有启动应用、没有合成输入、没有重建 player。

## 改前（真机，build 229，正在跑的这一次）

来源：`$HOME/Library/Logs/DefaultCompany/GMGN Unity Sample/Player.log`
（`/Applications/gmgn radio.app` 内嵌 Unity player 的日志；进程名是产品自带的
`GMGN Unity Sample`）。本次取的是 `Player.log` 里 19:10:42 开始的那一次冷启动。

### 锚点

| 时刻 | 行 | 说明 |
|---|---|---|
| `19:10:42.618` | `[UnityMediaHost] world startup scheduled: candidates=1` | 启动落空间的第一次尝试 |
| `19:10:43.988` | `[UnityMediaHost] world startup authority read: world=84503420-3010-4944-8fde-2f383cd08ebe` | 权威读到这个世界（+1.370 s） |
| `19:10:46.778` | `[UnityMediaHost] world selection: … phase=prepare revision=1`；`world selection assets: entries=7` | 准备事务开始（+2.790 s） |
| （无时间戳） | `[WorldPrepare] step=open` → `step=scene marble=False` → `[GaussianWorld] show cached=False cpuMs=23.75` → `step=items entries=7` → `step=recover.begin objects=9` → 7 × (`phase=metadata` → `phase=resolve` → `phase=load`) → `step=recover.done objects=7` → `step=ready items=7` | **整段 17.107 s** |
| `19:11:03.885` | `[UnityMediaHost] world selection: … phase=activate revision=1` | 渲染侧确认可见（+17.107 s） |
| `19:11:04.066` | `[UnityActivityPhase] snapshot phase=idle revision=8037011 …` | 第一次活动快照（+0.181 s） |

### 总耗时（改前）

| 段 | 耗时 | 备注 |
|---|---|---|
| 启动 → 调度落空间 | — | 日志起点是 Unity 自己的 `Metal RecreateSurface`，无时间戳 |
| 调度 → 权威读到世界 | **1.370 s** | `world startup scheduled` → `authority read` |
| 权威 → 准备事务开始 | **2.790 s** | 含 `spaceLibrary` 快照 + 生成物目录构建（`UnityGeneratedAssetCatalog.update`，7 条） |
| 准备事务 → `phase=activate` | **17.107 s** | 七个生成物**串行**恢复；这一段里宿主与界面没有任何一句话 |
| `activate` → 第一次活动快照 | **0.181 s** | |
| **冷启动到"空间真的在画面里"** | **21.267 s** | 19:10:42.618 → 19:11:03.885 |

### 每步耗时：**改前拿不到**

`Player.log` 在准备窗口里**只有两个时间戳**（`46.778` 与 `03.885`），因为
`[WorldPrepare] step=…` 全是 `Debug.Log`，Unity 不给它们加时间；带时间的是宿主的
`NSLog`，而那 17 秒里宿主一句话都没说。窗口里能看到的只有间接证据：

- `[GaussianWorld] show cached=False cpuMs=23.75` —— 场景缓存是**冷**的，现场解一次；
- 恢复期间夹着 `GPU frame timing cpuMs=172.629` —— 主线程正被资产装载占着
  （对照：准备完成后是 `cpuMs=14.805`）。

**所以"每步耗时"这件事，改前是测不到的**，这也是本次要补的一件东西（见下）。

## 改后（设计值；真机值需要一次重建 player 的冷启动）

### 加载态的形状

| 性质 | 改前 | 改后 |
|---|---|---|
| 进门前的界面 | 无（只有 `main.rs:416` 的一句 `正在连接原应用场景…`，无进度、无上界、无失败名） | `StartupGatePane` 盖住整窗：标题、`n/m 项已就绪`、进度条、**每个挡人步骤的名字与状态**、具名失败块与「重试」 |
| 步骤可见性 | 无 | 31 项清单（10 项挡人 / 17 项判定 / 4 项进门后按需），挡人项逐个列名 |
| 上界 | 渲染侧 120 s；宿主 180 s watchdog（只在回执丢失时）；**界面无上界** | 每项自己的 `budget_ms`，整体 `STARTUP_DEADLINE_MS = 150_000 ms`；到点只会变成 `<id>_timeout` / `<id>_deadline` / `<id>_blocked_by_*` |
| 失败 | 进门后弹一句（`真实空间网格生成失败，摆放尚未启用。` 等 31 条） | 进门前**具名**（项名 + 码 + 第几次尝试）+ 可重试 |
| 并行度 | 生成物恢复**串行**（7 个物件逐个 metadata→resolve→load） | 加载态这一层对 31 项**并行**推进（只有显式声明的依赖会等：`world.authorize → world.prepare → world.activate → placement.*`）；生成物恢复本身的串行在渲染侧，本次**没有**改 |

> 关于并行度的一句实话：**加载态不会让那 17.107 s 变短**。它做的是把这段时间
> 变成"有步骤名、有上界、失败具名"的等待，并把**本来可以提前做的判定**（摆放网格、
> 物件几何可读性、物理探针、生成服务健康、能力容量形状）提前到这段时间里。
> 真正的缩短要靠把 7 个物件的恢复并行化（`WorldSceneRecovery`，渲染侧，本次未改）。

### 每步耗时的取法（改后）

加载态自己会写时间线，一次真机冷启动即可 `grep` 出表：

```sh
# 宿主 stderr（或 Console.app 里 gmgn radio 的那一段）
grep -E 'GMGN_STARTUP_(STEP|READY|FAILED)' <log>
```

每行形如：

```
GMGN_STARTUP_STEP step=host.surface from=Running phase=Ready at_ms=812 code=-
GMGN_STARTUP_STEP step=world.prepare from=Running phase=Ready at_ms=18422 code=-
GMGN_STARTUP_STEP step=placement.grid from=Running phase=Unavailable at_ms=38422 code=world_grid_unavailable
GMGN_STARTUP_READY attempt=1 elapsed_ms=38461
```

`at_ms` 是**从加载态开始**的单调毫秒，不是墙钟；`from`/`phase` 是状态转移，
`code` 是具名码。于是"每一步花了多久" = 该项 `Ready` 的 `at_ms` 减去它进入
`Running` 的 `at_ms`（同一 `step=` 的相邻两行）。

### 各项的上界（设计值，供对照真机）

| 项 | 上界 |
|---|---|
| `host.core` | 5 s |
| `host.snapshot` | 10 s |
| `host.surface` / `window.mode` | 20 s |
| `world.authority` | 30 s |
| `world.prepare` | **120 s**（＝ 渲染侧 `PrepareBudget`，`WorldRuntimeBridge.cs:60`） |
| `world.activate` / `resident.queue` | 30 s |
| `resident.session` / `resident.agent` | 45 s |
| `placement.*` / `world.physics` / `cache.scene` | 20 s |
| `ui.*` | 15 s（`ui.program`/`ui.playlist` 20 s） |
| `prop.capability` | 10 s |
| `generation.health` | 10 s（其中 `/health` 请求本身 5 s，`PropGenerationClient.swift:14`） |
| **整体** | **150 s** |

## 为什么这里没有"改后真机时间线"

红线是**不打包、不装机、不点界面/不抢焦点**。改后的冷启动时间线需要
**重建 Unity player** 并**真的启动一次产品应用**，两者都在红线内被禁止，
而且 21.267 s 里的 17.107 s 发生在渲染侧（本次未改那一侧），所以它**本来也不会变**。

可以做的、也已经做了的：让"下一次冷启动"自己产出每步耗时（`GMGN_STARTUP_STEP`），
并且把每一条"进门后才发现的没 ready"绑定到清单里的某一项（`RETIRED_COPY`）。
