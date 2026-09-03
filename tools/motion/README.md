# 离线动作工厂

这套工具把 Linux 或 DGX 上的 ARDY 生成结果发布为客户端可下载的动作目录。生成端不进入 macOS 应用；客户端只下载、校验、缓存和播放动作。

```text
文字提示
  -> text-to-vrma ARDY 服务 /generate
  -> 动作 JSON 校验
  -> VRMA / 无手指 VMD 生成
  -> catalog.json + SHA-256
  -> HTTPS 静态目录
  -> gmgn radio 设置 > 角色与动作 > 动作库
```

## 0. 动作生成 API

gmgn radio 内置的本机动作库地址是：

```text
http://127.0.0.1:8765/catalog.json
```

启动一体化生成与下载服务：

```bash
python3 -m tools.motion.gmgn_motion_service \
  --ardy-url http://127.0.0.1:2337 \
  --output-root /data/gmgn-motion-catalog \
  --host 127.0.0.1 \
  --port 8765 \
  --public-base-url http://127.0.0.1:8765
```

提交生成任务：

```bash
curl -X POST http://127.0.0.1:8765/api/v1/motions \
  -H 'Content-Type: application/json' \
  --data '{
    "prompt": "双手在身体两侧做轻快的八拍舞蹈，保持双脚落地",
    "name": "八拍舞蹈",
    "duration": 8,
    "loop": true,
    "strideSpeed": 0.9,
    "playbackRate": 1.0,
    "inPlace": true,
    "format": "vmd",
    "waypoints": [
      {"x": 0.8, "z": 0.4},
      {"x": 1.6, "z": -0.2}
    ],
    "activityIDs": ["music.dance"]
  }'
```

`waypoints` 可选，表示 ARDY 地面路径点，按数组顺序行走。每个点使用米制的
`x`、`z` 坐标；动作自身产生的垂直位移仍由 ARDY 写入根节点 `y`，导出时会完整保留。
`loop` 可选；设为 `true` 时，发布结果会明确标记为循环动作，不依赖生成模型自行判断。
行走动作再提供 `strideSpeed`（米/秒）、`playbackRate` 和 `inPlace`。客户端用
同一份元数据同步导航速度和动作节奏；VMD 本身没有这套标准字段，必须随发布目录保存。

服务立即返回 `jobID` 和 `statusURL`。生成在后台单任务执行，不会占住调用端。查询任务：

```bash
curl http://127.0.0.1:8765/api/v1/motions/你的任务号
```

状态变为 `succeeded` 后，结果包含 `downloadURL` 和 `catalogURL`。打开 gmgn radio 的“设置 → 角色与动作 → 动作库”，点击“获取动作列表”，再点击对应动作的“安装”。VMD 对应 PMX，VRMA 对应 VRM。

本地只验证 API 和下载链时，可以用固定动作数据代替 ARDY：

```bash
python3 -m tools.motion.gmgn_motion_service \
  --preview-spec tools/motion/fixtures/local-preview-dance.json \
  --output-root /tmp/gmgn-motion-catalog-preview
```

这个预览模式只验证生成任务、发布和下载，不会根据文字改变动作内容。

GPU 服务暂时不可用时，Codex 也可以把已校验的骨骼动作数据放进 `motionSpec` 字段，再提交同一个 API。示例：

```bash
curl -X POST http://127.0.0.1:8765/api/v1/motions \
  -H 'Content-Type: application/json' \
  --data-binary @tools/motion/fixtures/right-hand-wave-request.json
```

这条路径会绕过 ARDY，但仍执行骨骼白名单、数值边界、无手指 VMD、哈希和不可变版本校验。

## 1. Linux 机器预检

在仓库根目录执行：

```bash
python3 tools/motion/gmgn_motion_factory.py preflight
```

16GB 内存、8GB 显存的机器需要提供足够的交换空间，使内存与可用交换空间合计至少达到 32GB。该配置会被标记为 `constrained`，并且只允许一个生成任务。32GB 以上内存、8GB 显存会被标记为 `ready`。

可以在不读取本机硬件的情况下检查目标配置：

```bash
python3 tools/motion/gmgn_motion_factory.py preflight \
  --memory-gib 16 \
  --swap-gib 32 \
  --vram-gib 8
```

## 2. 安装并启动 ARDY

ARDY 服务来自 [text-to-vrma](https://github.com/Kirakun0328/text-to-vrma)。先在目标 Linux 机器克隆该仓库，再执行它提供的安装脚本：

```bash
git clone https://github.com/Kirakun0328/text-to-vrma.git
cd text-to-vrma
bash tools/ardy-engine/install_linux.sh --engine-root /data/text-to-vrma/ardy-engine
```

安装脚本会给出 `server.py` 的完整启动命令。16GB 机器必须让文本编码器留在 CPU，并保持单进程：

```bash
export TEXT_ENCODER_DEVICE=cpu
export HF_HOME=/data/text-to-vrma/ardy-engine/hf-cache
/data/text-to-vrma/ardy-engine/venv/bin/python \
  tools/ardy-engine/server.py \
  --merged-base /data/text-to-vrma/ardy-engine/llm2vec-base-merged \
  --no-translate
```

服务准备完成后，以下请求应返回 `status=ok`：

```bash
curl http://127.0.0.1:2337/health
```

ARDY 服务只需监听本机；不要直接暴露到公网。

## 3. 生成并发布动作

```bash
python3 tools/motion/gmgn_motion_factory.py generate \
  --ardy-url http://127.0.0.1:2337 \
  --prompt "dance gently while stirring a pot" \
  --duration 8 \
  --seed 17 \
  --id gmgn.motion.kitchen-stir-dance \
  --name "Kitchen Stir Dance" \
  --version 1.0.0 \
  --activity cooking.stir \
  --activity music.dance \
  --revision abe6c43 \
  --format vmd \
  --output-root /data/gmgn-motion-catalog
```

产物结构：

```text
/data/gmgn-motion-catalog/
  catalog.json
  motions/
    gmgn.motion.kitchen-stir-dance/
      1.0.0/
        gmgn.motion.kitchen-stir-dance.vmd
```

同一动作编号和版本是不可变的；内容变化必须提升版本。发布器会拒绝未知骨骼、非有限数值、越界根位移和不合法元数据。`--format vrma` 用于 VRM；`--format vmd` 用于 PMX。PMX 动作不输出手指轨道，并保留 ARDY 给出的 X/Y/Z 根位移。

本机联调可以临时提供静态下载：

```bash
python3 tools/motion/gmgn_motion_factory.py publish-spec \
  --spec tools/motion/fixtures/local-preview-dance.json \
  --id gmgn.motion.local-preview-dance \
  --name "Local Preview Dance" \
  --version 1.0.0 \
  --activity music.dance \
  --prompt "local preview dance" \
  --output-root /tmp/gmgn-motion-catalog-preview

python3 tools/motion/gmgn_motion_factory.py publish-spec \
  --spec tools/motion/fixtures/local-preview-dance.json \
  --id gmgn.motion.local-preview-dance-pmx \
  --name "Local Preview Dance PMX" \
  --version 1.0.0 \
  --activity music.dance \
  --prompt "local preview dance for PMX" \
  --format vmd \
  --output-root /tmp/gmgn-motion-catalog-preview

python3 -m http.server 8765 --directory /tmp/gmgn-motion-catalog-preview --bind 127.0.0.1
```

正式环境应使用 HTTPS 静态托管或对象存储。客户端会拒绝非 HTTPS 地址，只有 `localhost`、`127.0.0.1` 和 `::1` 可以使用 HTTP。

## 4. 导入 BONES-SEED 动作

通过 Bones Studio 授权后，可以把 BONES-SEED 的 SOMA BVH 转为 gmgn radio
使用的 VMD 或 VRMA。导入器会使用官方 SOMA 绑定姿态修正骨骼方向，并保留
动作中的三轴根位移。用于导航的循环行走建议把水平位移交给世界模拟，只保留
动作自身的上下起伏：

```bash
python3 tools/motion/gmgn_motion_factory.py import-bones \
  --motion neutral_walk_ff_180_R_002__A534.bvh \
  --profile tools/motion/profiles/bones-seed-soma-v1.json \
  --id gmgn.motion.bones.walk-loop-pmx \
  --name "BONES 行走循环" \
  --version 1.0.0 \
  --activity home.walk \
  --format vmd \
  --loop \
  --start-frame 728 \
  --end-frame 896 \
  --root-motion vertical-only \
  --output-fps 30 \
  --output-root /data/gmgn-motion-catalog
```

`--motion` 会从 BONES 官方查看器读取指定动作；已经下载的文件可改用
`--bvh /绝对路径/动作.bvh`。`--root-motion full` 保留 X/Y/Z，`none`
会锁住全部根位移。

BONES-SEED 是受限数据集。原始 BVH 不进入仓库，也不能随应用或动作目录重新
分发。生成结果的使用和发布必须符合 BONES Motion Capture Dataset License；
产品对外发布前需要再次确认商业许可。署名使用
[Motion Data by Bones Studio](https://bones.studio/)。

## 5. 客户端安装

打开“设置 → 角色与动作 → 动作库”，填写：

```text
https://你的动作域名/catalog.json
```

点击“刷新”，再点击动作旁边的“安装”。客户端会检查：

- 目录版本和重复编号；
- 下载地址是否同源；
- 文件大小是否超过 500MB；
- SHA-256 是否匹配；
- 文件是否包含有效的 VRM Animation 扩展或 VMD 文件头。

安装成功后，动作会进入现有“角色动作”菜单。VRMA 用于 VRM 角色；VMD 用于当前 2B 等 PMX 角色。

## 6. 验证

```bash
python3 -m unittest \
  tools.motion.tests.test_gmgn_motion_factory \
  tools.motion.tests.test_bones_seed_import

swift test \
  --package-path apps/macos/Packages/MotionDistribution \
  --scratch-path "$(mktemp -d)"
```

这两组测试不会启动 gmgn radio，也不会打开任何窗口。
