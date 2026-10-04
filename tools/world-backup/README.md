# 世界备份：第一阶段 portable staging

Python 3 标准库工具，不依赖引擎，不调用真实应用。只从显式传入的 `tasks.sqlite3` 的一致只读事务导出世界语义记录，保留所有 `world_records` 域（含 tombstone、revision、原始 JSON value），并保存 `world_imports` 包版本信息。不会拷贝 SQLite 整库。不会连接服务或改写 taskd：唯一 writer 语义保持不变。

## 使用

输出目录必须不存在，父目录必须存在。以下路径为示例，运行前替换成明确的世界/包目录，不要传整个 Application Support、home 或仓库。

```sh
python3 tools/world-backup/world_backup.py backup \
  --database /explicit/taskd-root/tasks.sqlite3 \
  --asset-root world=/explicit/world-package \
  --asset-root presence=/explicit/PresencePackages/selected-package \
  --asset-root motion=/explicit/MotionPackages/selected-package \
  --out /explicit/backups/world-001
python3 tools/world-backup/world_backup.py verify --bundle /explicit/backups/world-001
python3 tools/world-backup/world_backup.py recover \
  --bundle /explicit/backups/world-001 --out /explicit/recovery/new-world
python3 -m unittest discover -s tools/world-backup -p 'test_*.py' -v
```

每个 `--asset-root NAME=PATH` 整体纳入目录内所有常规文件：world package 应包含 `world.json`、`marble.json`、SPZ、碰撞/导航数据；人物包应包含 manifest、PMX/VRM、贴图与 selection 信息；动作包应包含 manifest、VMD/VRMA 及 selection。只能传世界相关资产目录；`.env`、凭据/会话目录、私钥扩展和符号链接会拒绝，发现问题不会生成成功包。文件名检查不能识别任意名称的秘密文件，使用者仍需确认输入目录归属。

另外保守纳入数据库全部 `world_blobs` 登记的原始本地文件，校验登记大小及 SHA256；没有本地资产（包括仅 remote_key 的登记）或内容损坏则失败，需先通过现有资产链路完成下载。当前没有推测引用可达性，因此未引用的旧 blob 也可能阻止备份，不能宣称支持单世界选择备份。`local_path` 与 `remote_key` 不作为 blob 元数据导出。

旧生成物件可能只在世界记录的 `assetID` 中保存 `sha256:<hash>`，没有 `world_blobs` 登记。此时重复传入 `--blob-file /explicit/one-generated-model.glb`：只纳入该常规 GLB 2.0 文件，计算出的 SHA256 必须匹配世界记录中的资产编号，并加入同一 blob 索引；重复哈希只登记一次。此参数不会扫描父目录，也不允许把 TaskService 整根作为资产目录。没有匹配、错误文件类型、符号链接或损坏 GLB 头部均拒绝。资产编号允许位于 metadata 的 JSON 字符串中，原始记录仍不重写。

记录的原始 authority hash 作为来源信息保留，不与重新序列化的 Python JSON 字节比较；这里只验证基础记录字段与包内文件完整性，不执行 taskd 的全部世界语义校验。macOS 系统 `/tmp`、`/var` 别名接受并归一到 `/private`，任意资产或包内符号链接仍拒绝。

## 格式与恢复边界

- `manifest.json`：格式标识、版本、全部有效负载文件的相对路径、大小、SHA256。
- `worlds.json`：世界记录、包信息、blob索引、资产根索引及 `referenceBindings`。
- `assets/<name>/...`、`blobs/<sha256>`：原始资产字节。

原始 value 不重写，可能保留旧机器的绝对路径和私密链接。`referenceBindings` 将识别出的本地绝对路径或 `file://` 引用映射到包内相对路径，未来引擎 adapter 必须相对于恢复目录解析它们。若原始引用的文件没有纳入资产范围，备份直接失败。相对引用需由对应 package manifest/root解析；本工具不推测每一种资产格式的内部依赖。未登记、未显式纳入的资产无法自动发现。备份作为私人用户数据保管，不默认打印原始元数据；SHA256用于完整性检查，不提供签名、防篡改认证或加密。

recover 首先完整验证输入，再复制到同父目录的临时目录并二次校验，最后发布为全新目录；不会覆盖任何现有目录。拒绝绝对/穿越路径、重复清单、未列出文件及符号链接。工具面对可信本地目录的离线操作，不能代替对恶意并发文件系统写入的沙箱。

**这一步恢复的是可迁移 staging，不是 App 一键恢复，也不导入 taskd。** 不导出 facts 历史、requests 幂等记录、consumer cursors、jobs、消息、凭据或运行会话。当前电视配置尚未写入世界 authority 的内容无法从本工具备份。后续引擎 adapter 需处理旧路径重绑定及导入合同，再通过 taskd 正式写入接口恢复；禁止直接写 live SQLite。无权威表的旧 Swift `state.json` 应先按现有 world-migration 工具处理，不混合两种 authority。

测试只创建临时 fixture：运行 CLI 备份、删除 fixture 源、恢复到新根，逐一比较所有域和原始资产 hash并验证映射不依赖旧根；包含损坏、缺失、路径穿越、符号链接、敏感文件、既有目标与版本错误负测试。未操作真实用户世界，未证明当前 App 可直接消费恢复目录。
