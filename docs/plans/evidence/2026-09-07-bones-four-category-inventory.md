# BONES 动作库：生活、工作、运动、戏剧

日期：2026-09-07。范围是本机已安装 BONES 包与已缓存的官方元数据；没有下载新动作、调用 ARDY、替换已安装素材或扩大居民自动活动白名单。

## 结论与计数口径

已安装 **352 个 BONES 格式包**，合并 PMX / VRM 后为 **178 个动作条目**。另有四个非 BONES 已安装包，不计入下面四类的数量。178 是动作库条目数，**未按原始录制来源去重**；例如自然待机、持物循环可能与 ARPG 完整片段同源。行走的 PMX 和 VRM 版本也不是同一源片段，合并显示不代表字节、时长或校准参数相同。

| 主类 | 动作条目 | 格式包 | 现有内容 |
|---|---:|---:|---|
| 生活 | 28 | 52 | 待机、坐姿、拾取、持物、放置、门交互、咖啡按钮 |
| 工作 | 3 | 6 | 连续思考、高位和中位设备按钮 |
| 运动 | 124 | 248 | 走跑起停、转向、蹲行、跳跃、跨越、梯子、楼梯、翻滚、开合跳 |
| 戏剧 | 23 | 46 | 警戒、战斗姿态、闪避、直拳组合、受击、昏厥、倒地与起身 |

按主要用途归类，允许动作跨场景复用。普通站立归生活，警戒站立归戏剧；通用设备按钮归工作，已命名的咖啡按钮归生活；走跑、楼梯、翻滚归运动；本批以战斗用途选择的直拳组合归戏剧。它们是浏览归类，不改变原片段语义。

## 源库已找到、尚未入库的候选

以下条目逐项核对了文件名、自然描述和技术描述。源库有动作并不代表当前模型已适配，也不代表房间已有配套道具与活动。

| 主类 | 候选用途 | 真实 BONES 来源 | 注意事项 |
|---|---|---|---|
| 生活 | 盘腿打盹 | `dozing_cross_legged_R_001__A428` | 描述包含坐下盘腿、打盹、突然醒来；不能直接当作整夜卧睡循环。 |
| 生活 | 站立喝杯中饮品 | `drinking_standing_mug_R_001__A287` | 需要杯子、握持和入口接触适配。 |
| 生活 | 坐在桌旁喝饮品 | `drinking_table_mug_R_001__A287` | 来源桌高约 67 厘米，需要椅子和桌面定位。 |
| 生活 | 坐姿双手吃汉堡 | `eat_burger_both_hands_sitting_R_001__A456` | 需要食物和双手接触适配；不是通用吃饭循环。 |
| 工作 | 坐姿双手读书 | `read_book_both_hands_sitting_R_003__A456` | 技术描述明确双手持书；同名 001 变体的技术描述为右手持书，未混用。 |
| 工作 | 坐姿读报 | `read_newspaper_sitting_R_001__A456` | 包含翻页与折报，需要报纸。 |
| 工作 | 坐姿手机输入 | `cellphone_typing_sitting_one_hand_idle_R_001__A423` | 掏手机、单手输入、收手机的完整序列；不能替代电脑键盘打字。 |

源元数据共 142,220 行，包含镜像、演员与动作变体；不应把行数直接叫作独立动作数量。已安装的连续思考确实存在，缺的是更多工作场景动作及活动接线，不能把“没看到居民做”理解为“没有思考素材”。

## 仍待补充的缺项

| 缺项 | 本轮证据 | 后续顺序 |
|---|---|---|
| 桌前键盘打字、鼠标操作 | 对文件名和文字描述检索 computer / keyboard，并补查 laptop / desk / typewriter 的文件名，未找到明确匹配；手机输入仅是邻近素材。 | 先继续核对 BONES 的工作语义与目标桌椅，再考虑 ARDY 定向补充。 |
| 卧睡、稳定呼吸、打呼噜 | 查到盘腿打盹；尚未确认卧睡与 snore 来源。昏厥、仰卧起身不能替代睡眠。 | 需要入睡、保持、醒来姿态及声音配合，再决定来源；本轮不生成。 |
| 日常交谈、情绪表达与更多生活工作动作 | 本批最初面向 ARPG，主要覆盖运动和戏剧；完整源库还包含 Household、Consuming、Communication、Gestures 等分类。 | 按实际生活活动先挑源片段，不把源库整类批量导入。 |

ARDY 只作为缺项补充候选，本轮没有提交生成任务。

## 接地与居民活动边界

- 本轮仅做目录归类。大多数 ARPG 动作仍待真实角色视觉验收，不自动成为居民可调用活动。
- 两条 recovery 动作的根高度与接触约定存在问题，DSH 正在限定范围做离线候选校准；候选通过前，不提升“可安全使用”状态。
- 不给全库统一抬高；站姿、跳跃、楼梯、躺姿所需的接触规则不同。
- 格式可见性应独立于底层转接能力：PMX 界面显示 VMD 与通用自然待机，VRM 界面显示 VRMA 与通用自然待机。VMD→VRM 的既有播放能力不作为双份列表的理由。
- 完整清单中的“格式”只说明已安装版本，不表示验收通过。

## 已安装完整清单

表中编号去掉共同前缀 `gmgn.motion.bones.`，其后另有 `-pmx` 或 `-vrm`。ARPG 条目保留子分类；居民动作保留现有包名。非 ARPG 旧包仅列已核实的动作库身份，不补造未核实的源文件名。

### 生活

| 动作编号 | 名称 | 子类 | 已安装格式 |
|---|---|---|---|
| `arpg.idle-neutral` | 自然站立待机 | 待机与警戒 | PMX / VRM |
| `arpg.idle-staggered` | 右脚前置站姿 | 待机与警戒 | PMX / VRM |
| `arpg.interact-door-knock` | 敲门 | 门与机关交互 | PMX / VRM |
| `arpg.interact-door-open` | 打开内侧左开门 | 门与机关交互 | PMX / VRM |
| `arpg.interact-door-pass-close` | 开门通过后关门 | 门与机关交互 | PMX / VRM |
| `arpg.interact-door-pull` | 拉门把手 | 门与机关交互 | PMX / VRM |
| `arpg.object-hold-large` | 双手持轻大物件 | 持物交互 | PMX / VRM |
| `arpg.object-hold-small` | 单手持小物件 | 持物交互 | PMX / VRM |
| `arpg.object-hold-small-long` | 单手持续持小物件 | 持物交互 | PMX / VRM |
| `arpg.object-switch-hands` | 将物件换手 | 持物交互 | PMX / VRM |
| `arpg.pickup-crouch-walking` | 蹲行中拾取物件 | 拾取交互 | PMX / VRM |
| `arpg.pickup-crouched` | 蹲姿拾取物件 | 拾取交互 | PMX / VRM |
| `arpg.pickup-front-high` | 拿取前方高处小物件 | 拾取交互 | PMX / VRM |
| `arpg.pickup-front-medium` | 拿取前方中位小物件 | 拾取交互 | PMX / VRM |
| `arpg.pickup-jogging` | 慢跑中拾取物件 | 拾取交互 | PMX / VRM |
| `arpg.pickup-side-high` | 拿取右侧高处小物件 | 拾取交互 | PMX / VRM |
| `arpg.pickup-standing` | 站立拾取地面物件 | 拾取交互 | PMX / VRM |
| `arpg.pickup-walking` | 行走中拾取物件 | 拾取交互 | PMX / VRM |
| `arpg.place-front-high` | 放置小物件到前方高处 | 放置交互 | PMX / VRM |
| `arpg.place-front-low` | 放置小物件到前方低处 | 放置交互 | PMX / VRM |
| `arpg.place-front-medium` | 放置小物件到前方中位 | 放置交互 | PMX / VRM |
| `arpg.place-side-low` | 放置小物件到右侧低处 | 放置交互 | PMX / VRM |
| `chair-sit-loop` | 椅子坐姿 | 居民动作 | PMX |
| `coffee-button` | 操作咖啡机 | 居民动作 | PMX |
| `cross-legged-loop` | 盘腿坐 | 居民动作 | PMX |
| `hold-display` | 单手持小物件 | 居民动作 | PMX / VRM |
| `idle-loop` | 自然待机 | 居民动作 | PMX / VRM |
| `kneeling-loop` | 跪坐 | 居民动作 | PMX |

### 工作

| 动作编号 | 名称 | 子类 | 已安装格式 |
|---|---|---|---|
| `arpg.interact-button-high` | 按高位按钮 | 门与机关交互 | PMX / VRM |
| `arpg.interact-button-mid` | 按中位按钮 | 门与机关交互 | PMX / VRM |
| `thinking-loop` | 连续思考 | 居民动作 | PMX / VRM |

### 运动

| 动作编号 | 名称 | 子类 | 已安装格式 |
|---|---|---|---|
| `arpg.arc-jog-loop` | 顺时针弧线慢跑移动 | 弧线移动 | PMX / VRM |
| `arpg.arc-jog-start` | 顺时针弧线慢跑起步 | 弧线移动 | PMX / VRM |
| `arpg.arc-jog-stop` | 顺时针弧线慢跑停止 | 弧线移动 | PMX / VRM |
| `arpg.arc-walk-loop` | 顺时针弧线行走移动 | 弧线移动 | PMX / VRM |
| `arpg.arc-walk-start` | 顺时针弧线行走起步 | 弧线移动 | PMX / VRM |
| `arpg.arc-walk-stop` | 顺时针弧线行走停止 | 弧线移动 | PMX / VRM |
| `arpg.crouch-back-right` | 向右后蹲伏移动 | 蹲伏 | PMX / VRM |
| `arpg.crouch-backward` | 向后蹲伏移动 | 蹲伏 | PMX / VRM |
| `arpg.crouch-forward` | 向前蹲伏移动 | 蹲伏 | PMX / VRM |
| `arpg.crouch-forward-right` | 向右前蹲伏移动 | 蹲伏 | PMX / VRM |
| `arpg.crouch-idle` | 蹲伏待机 | 蹲伏 | PMX / VRM |
| `arpg.crouch-right` | 向右蹲伏移动 | 蹲伏 | PMX / VRM |
| `arpg.crouch-start` | 向前蹲伏起步 | 蹲伏 | PMX / VRM |
| `arpg.crouch-stop` | 向前蹲伏停止 | 蹲伏 | PMX / VRM |
| `arpg.jog-back-left-loop` | 向左后慢跑移动（官方镜像） | 慢跑移动 | PMX / VRM |
| `arpg.jog-back-left-start` | 向左后慢跑起步（官方镜像） | 慢跑起步 | PMX / VRM |
| `arpg.jog-back-left-stop` | 向左后慢跑停止（官方镜像） | 慢跑停止 | PMX / VRM |
| `arpg.jog-back-right-loop` | 向右后慢跑移动 | 慢跑移动 | PMX / VRM |
| `arpg.jog-back-right-start` | 向右后慢跑起步 | 慢跑起步 | PMX / VRM |
| `arpg.jog-back-right-stop` | 向右后慢跑停止 | 慢跑停止 | PMX / VRM |
| `arpg.jog-backward-loop` | 向后慢跑移动 | 慢跑移动 | PMX / VRM |
| `arpg.jog-backward-start` | 向后慢跑起步 | 慢跑起步 | PMX / VRM |
| `arpg.jog-backward-stop` | 向后慢跑停止 | 慢跑停止 | PMX / VRM |
| `arpg.jog-forward-left-loop` | 向左前慢跑移动（官方镜像） | 慢跑移动 | PMX / VRM |
| `arpg.jog-forward-left-start` | 向左前慢跑起步（官方镜像） | 慢跑起步 | PMX / VRM |
| `arpg.jog-forward-left-stop` | 向左前慢跑停止（官方镜像） | 慢跑停止 | PMX / VRM |
| `arpg.jog-forward-loop` | 向前慢跑移动 | 慢跑移动 | PMX / VRM |
| `arpg.jog-forward-right-loop` | 向右前慢跑移动 | 慢跑移动 | PMX / VRM |
| `arpg.jog-forward-right-start` | 向右前慢跑起步 | 慢跑起步 | PMX / VRM |
| `arpg.jog-forward-right-stop` | 向右前慢跑停止 | 慢跑停止 | PMX / VRM |
| `arpg.jog-forward-start` | 向前慢跑起步 | 慢跑起步 | PMX / VRM |
| `arpg.jog-forward-stop` | 向前慢跑停止 | 慢跑停止 | PMX / VRM |
| `arpg.jog-left-loop` | 向左慢跑移动（官方镜像） | 慢跑移动 | PMX / VRM |
| `arpg.jog-left-start` | 向左慢跑起步（官方镜像） | 慢跑起步 | PMX / VRM |
| `arpg.jog-left-stop` | 向左慢跑停止（官方镜像） | 慢跑停止 | PMX / VRM |
| `arpg.jog-right-loop` | 向右慢跑移动 | 慢跑移动 | PMX / VRM |
| `arpg.jog-right-start` | 向右慢跑起步 | 慢跑起步 | PMX / VRM |
| `arpg.jog-right-stop` | 向右慢跑停止 | 慢跑停止 | PMX / VRM |
| `arpg.jump-back-left` | 向左后小跳 | 方向跳跃 | PMX / VRM |
| `arpg.jump-back-right` | 向右后小跳（官方镜像） | 方向跳跃 | PMX / VRM |
| `arpg.jump-backward` | 向后小跳 | 方向跳跃 | PMX / VRM |
| `arpg.jump-forward` | 向前小跳 | 方向跳跃 | PMX / VRM |
| `arpg.jump-forward-left` | 向左前小跳 | 方向跳跃 | PMX / VRM |
| `arpg.jump-forward-right` | 向右前小跳（官方镜像） | 方向跳跃 | PMX / VRM |
| `arpg.jump-high-up` | 原地高跳 | 原地跳跃 | PMX / VRM |
| `arpg.jump-left` | 向左小跳 | 方向跳跃 | PMX / VRM |
| `arpg.jump-right` | 向右小跳 | 方向跳跃 | PMX / VRM |
| `arpg.jump-up` | 原地起跳落地 | 原地跳跃 | PMX / VRM |
| `arpg.ladder-down-loop` | 连续下梯 | 梯子攀爬 | PMX / VRM |
| `arpg.ladder-down-start` | 开始下梯 | 梯子攀爬 | PMX / VRM |
| `arpg.ladder-down-stop` | 停止下梯 | 梯子攀爬 | PMX / VRM |
| `arpg.ladder-idle` | 梯上停留 | 梯子攀爬 | PMX / VRM |
| `arpg.ladder-jump-off` | 从梯子跳落地面 | 梯子攀爬 | PMX / VRM |
| `arpg.ladder-step-off` | 从梯子踏回地面 | 梯子攀爬 | PMX / VRM |
| `arpg.ladder-up-start-alternating` | 手脚交替开始爬梯 | 梯子攀爬 | PMX / VRM |
| `arpg.ladder-up-start-symmetric` | 双侧同步开始爬梯 | 梯子攀爬 | PMX / VRM |
| `arpg.platform-off-1m` | 从1米平台跳落 | 平台跳上跳落 | PMX / VRM |
| `arpg.platform-off-back-50cm` | 从50厘米平台向后跳落 | 平台跳上跳落 | PMX / VRM |
| `arpg.platform-off-front-50cm` | 从50厘米平台向前跳落 | 平台跳上跳落 | PMX / VRM |
| `arpg.platform-on-1m` | 跳上1米平台 | 平台跳上跳落 | PMX / VRM |
| `arpg.platform-on-50cm` | 跳上50厘米平台 | 平台跳上跳落 | PMX / VRM |
| `arpg.roll-landing-shoulder` | 跳落后肩部卸力翻滚 | 翻滚 | PMX / VRM |
| `arpg.roll-long-jump-shoulder` | 长跳后肩部卸力翻滚 | 翻滚 | PMX / VRM |
| `arpg.roll-side-left` | 向左侧翻滚（官方镜像） | 翻滚 | PMX / VRM |
| `arpg.roll-side-right` | 向右侧翻滚 | 翻滚 | PMX / VRM |
| `arpg.sprint-forward-loop` | 向前冲刺循环 | 冲刺 | PMX / VRM |
| `arpg.sprint-forward-start` | 向前冲刺起步 | 冲刺 | PMX / VRM |
| `arpg.sprint-forward-stop` | 向前冲刺停止 | 冲刺 | PMX / VRM |
| `arpg.stairs-jog-down-loop` | 跑下楼梯 | 楼梯移动 | PMX / VRM |
| `arpg.stairs-jog-down-stop` | 跑下楼梯后停止 | 楼梯移动 | PMX / VRM |
| `arpg.stairs-jog-up-start` | 开始跑上楼梯 | 楼梯移动 | PMX / VRM |
| `arpg.stairs-walk-down-loop` | 走下楼梯 | 楼梯移动 | PMX / VRM |
| `arpg.stairs-walk-down-stop` | 下楼梯到达地面 | 楼梯移动 | PMX / VRM |
| `arpg.stairs-walk-up-start` | 开始走上楼梯 | 楼梯移动 | PMX / VRM |
| `arpg.turn-idle-left-135` | 左转135度 | 原地转身 | PMX / VRM |
| `arpg.turn-idle-left-180` | 左转180度 | 原地转身 | PMX / VRM |
| `arpg.turn-idle-left-45` | 左转45度 | 原地转身 | PMX / VRM |
| `arpg.turn-idle-left-90` | 左转90度 | 原地转身 | PMX / VRM |
| `arpg.turn-idle-right-135` | 右转135度（官方镜像） | 原地转身 | PMX / VRM |
| `arpg.turn-idle-right-180` | 右转180度 | 原地转身 | PMX / VRM |
| `arpg.turn-idle-right-45` | 右转45度（官方镜像） | 原地转身 | PMX / VRM |
| `arpg.turn-idle-right-90` | 右转90度 | 原地转身 | PMX / VRM |
| `arpg.turn-jog-left-180` | 左转180度后慢跑 | 转身移动 | PMX / VRM |
| `arpg.turn-jog-left-90` | 左转90度后慢跑 | 转身移动 | PMX / VRM |
| `arpg.turn-jog-right-180` | 右转180度后慢跑 | 转身移动 | PMX / VRM |
| `arpg.turn-jog-right-90` | 右转90度后慢跑 | 转身移动 | PMX / VRM |
| `arpg.turn-walk-left-180` | 左转180度后行走 | 转身移动 | PMX / VRM |
| `arpg.turn-walk-left-90` | 左转90度后行走 | 转身移动 | PMX / VRM |
| `arpg.turn-walk-right-180` | 右转180度后行走 | 转身移动 | PMX / VRM |
| `arpg.turn-walk-right-90` | 右转90度后行走 | 转身移动 | PMX / VRM |
| `arpg.vault-150cm-left` | 左手支撑翻越1.5米障碍 | 跨越翻越 | PMX / VRM |
| `arpg.vault-150cm-right` | 右手支撑翻越1.5米障碍 | 跨越翻越 | PMX / VRM |
| `arpg.vault-1m-left` | 左手支撑翻越1米障碍 | 跨越翻越 | PMX / VRM |
| `arpg.vault-1m-right` | 右手支撑翻越1米障碍 | 跨越翻越 | PMX / VRM |
| `arpg.vault-2m-right` | 右手支撑翻越2米障碍 | 跨越翻越 | PMX / VRM |
| `arpg.vault-50cm-right` | 右手支撑翻越50厘米障碍 | 跨越翻越 | PMX / VRM |
| `arpg.vault-75cm-no-hands` | 无手支撑跨越75厘米障碍 | 跨越翻越 | PMX / VRM |
| `arpg.vault-75cm-right` | 右手支撑翻越75厘米障碍 | 跨越翻越 | PMX / VRM |
| `arpg.walk-back-left-loop` | 向左后行走移动 | 行走移动 | PMX / VRM |
| `arpg.walk-back-left-start` | 向左后行走起步 | 行走起步 | PMX / VRM |
| `arpg.walk-back-left-stop` | 向左后行走停止 | 行走停止 | PMX / VRM |
| `arpg.walk-back-right-loop` | 向右后行走移动 | 行走移动 | PMX / VRM |
| `arpg.walk-back-right-start` | 向右后行走起步 | 行走起步 | PMX / VRM |
| `arpg.walk-back-right-stop` | 向右后行走停止 | 行走停止 | PMX / VRM |
| `arpg.walk-backward-loop` | 向后行走移动 | 行走移动 | PMX / VRM |
| `arpg.walk-backward-start` | 向后行走起步 | 行走起步 | PMX / VRM |
| `arpg.walk-backward-stop` | 向后行走停止 | 行走停止 | PMX / VRM |
| `arpg.walk-forward-left-loop` | 向左前行走移动 | 行走移动 | PMX / VRM |
| `arpg.walk-forward-left-start` | 向左前行走起步 | 行走起步 | PMX / VRM |
| `arpg.walk-forward-left-stop` | 向左前行走停止 | 行走停止 | PMX / VRM |
| `arpg.walk-forward-loop` | 向前行走移动 | 行走移动 | PMX / VRM |
| `arpg.walk-forward-right-loop` | 向右前行走移动 | 行走移动 | PMX / VRM |
| `arpg.walk-forward-right-start` | 向右前行走起步 | 行走起步 | PMX / VRM |
| `arpg.walk-forward-right-stop` | 向右前行走停止 | 行走停止 | PMX / VRM |
| `arpg.walk-forward-start` | 向前行走起步 | 行走起步 | PMX / VRM |
| `arpg.walk-forward-stop` | 向前行走停止 | 行走停止 | PMX / VRM |
| `arpg.walk-left-loop` | 向左行走移动 | 行走移动 | PMX / VRM |
| `arpg.walk-left-start` | 向左行走起步 | 行走起步 | PMX / VRM |
| `arpg.walk-left-stop` | 向左行走停止 | 行走停止 | PMX / VRM |
| `arpg.walk-right-loop` | 向右行走移动 | 行走移动 | PMX / VRM |
| `arpg.walk-right-start` | 向右行走起步 | 行走起步 | PMX / VRM |
| `arpg.walk-right-stop` | 向右行走停止 | 行走停止 | PMX / VRM |
| `jumping-jacks` | 开合跳 | 居民动作 | PMX / VRM |
| `walk-loop` | 前向行走循环 | 居民动作 | PMX / VRM |

### 戏剧

| 动作编号 | 名称 | 子类 | 已安装格式 |
|---|---|---|---|
| `arpg.alert-enter` | 进入警戒姿态 | 待机与警戒 | PMX / VRM |
| `arpg.attack-straight-punch-combo-a359` | 徒手交替直拳组合（演员359） | 徒手攻击 | PMX / VRM |
| `arpg.attack-straight-punch-combo-a360` | 徒手交替直拳组合（演员360） | 徒手攻击 | PMX / VRM |
| `arpg.attack-straight-punch-combo-a361` | 徒手交替直拳组合（演员361） | 徒手攻击 | PMX / VRM |
| `arpg.attack-straight-punch-combo-a362` | 徒手交替直拳组合（演员362） | 徒手攻击 | PMX / VRM |
| `arpg.combat-turn-back-jog` | 进入战斗姿态后转起跑 | 战斗姿态移动 | PMX / VRM |
| `arpg.combat-turn-right-jog` | 进入战斗姿态右转起跑 | 战斗姿态移动 | PMX / VRM |
| `arpg.dodge-backward` | 后撤闪避 | 战斗闪避 | PMX / VRM |
| `arpg.dodge-duck` | 俯身闪避 | 战斗闪避 | PMX / VRM |
| `arpg.dodge-left` | 向左闪避（官方镜像） | 战斗闪避 | PMX / VRM |
| `arpg.dodge-right` | 向右闪避 | 战斗闪避 | PMX / VRM |
| `arpg.dodge-up` | 上跳闪避 | 战斗闪避 | PMX / VRM |
| `arpg.hit-air-spin-fall` | 遭回旋踢后旋转倒地 | 受击倒地 | PMX / VRM |
| `arpg.hit-air-spin-fall-mirror` | 遭回旋踢后旋转倒地（官方镜像） | 受击倒地 | PMX / VRM |
| `arpg.idle-alert` | 警戒观察待机 | 待机与警戒 | PMX / VRM |
| `arpg.recovery-faint` | 昏厥倒地 | 跌倒与起身 | PMX / VRM |
| `arpg.recovery-faint-recover-back` | 昏厥后从仰卧起身 | 跌倒与起身 | PMX / VRM |
| `arpg.recovery-faint-recover-side` | 昏厥后从侧卧起身 | 跌倒与起身 | PMX / VRM |
| `arpg.recovery-faint-side` | 昏厥侧倒 | 跌倒与起身 | PMX / VRM |
| `arpg.recovery-get-up-back` | 仰卧起身 | 跌倒与起身 | PMX / VRM |
| `arpg.recovery-get-up-front` | 俯卧起身 | 跌倒与起身 | PMX / VRM |
| `arpg.recovery-get-up-side` | 侧卧起身 | 跌倒与起身 | PMX / VRM |
| `arpg.recovery-run-fall` | 奔跑失足倒地 | 跌倒与起身 | PMX / VRM |

## 可复核依据

- 来源清单：`tools/motion/fixtures/bones-arpg.json`、`bones-resident.json` 与 `bones-walk-vrm.json`。
- 分类实现：`apps/macos/Sources/GMGNRadio/Presence/MotionLibraryCategory.swift`。
- 回归：`tools/test-motion-library-categories.swift`，覆盖全部 ARPG 条目双格式、九个居民键、四类顺序和未知编号边界。
- 官方本地元数据 SHA256：`71d09422034946d17dbb0db027d569408c486545bdb12f7979d55e6ffd9bbc39`，与原来源清单记录一致。
- 安装目录：`/Users/ghostcorn/Library/Application Support/gmgn radio/MotionPackages`。
- 候选依据是本地缓存官方元数据，没有把资料检索记为动作下载或宿主验收。

## 本轮界面接入与验证（20:33 构建）

- 设置与舞台动作库均支持“全部 / 生活 / 工作 / 运动 / 戏剧”。先按角色格式过滤，再按类别筛选；未知分类仍可在“全部”查看。
- PMX 列表显示 VMD 与程序动作，VRM 列表显示 VRMA 与程序动作；本地和远端目录采用相同规则。未删除已安装动作，也未收窄既有 VRM 转接播放能力。
- 从其他窗口切换角色时，设置动作库会跟随当前角色刷新。
- 格式过滤 26 项、分类全清单、实际设置模型投影、舞台控件回归均通过；macOS `build-for-testing` 通过。协议与离线工具循环回归分别通过 181 项和 103 + 21 项；这些均不代表宿主实际运行验收。
- 独立新包：`apps/macos/Build/Packages/gmgn-radio-20260907-2033-debug.zip`，压缩完整性检查通过。
- ZIP SHA256：`c65ced6b2c7192164d8bef1b16438551a475f4cdcd1e0a4b2d2dddf7219b84ff`。
- 本轮未启动宿主、未覆盖 Applications 安装、未触发钥匙串或系统授权。倒地起身校准仍为离线候选，不在此包中替换素材。
