#!/usr/bin/env python3
"""真实 App 端到端驱动：用户许愿 → 真实生成服务 → 入世界 → 摆放/手持 →
动作与电视播放 → 通知已读 → 重启恢复。

与 `tools/e2e-acceptance.py`（进程层，真 taskd/mcpd 但生成后端是回环夹具）不同，
本脚本启动的是**真正的 App 产物**，并让它用 `GMGN_E2E_DATA_ROOT` 把持久化与
UserDefaults 全部隔离到一次性目录里；它不安装、不启动、不重启已装宿主，也不读写
用户的真实 Application Support。

控制面是宿主 App 内、只在 `GMGN_E2E_DATA_ROOT` 显式设置时存在的文件邮箱
（见 `apps/macos/Sources/GMGNRadio/App/E2EHostControl.swift`）：

    <root>/control/inbox/<id>.json    驱动器写、宿主读
    <root>/control/outbox/<id>.json   宿主写、驱动器读

每一条命令都转发现有生产入口，驱动器**不**直接写世界权威、**不**直调
`world_commit`：

* `submit_wish`    → 真实用户提交门 `sendResidentSubmission`
* `wish_authorize` → `WishMachineCoordinator.registerImages` + `authorize`
* `tool_call`      → 居民当轮工具租约 `ResidentConversationTools.call`
* `capture_frames` → 居民视觉那条无权限 Metal drawable 回读
* `playback_state` / `inbox_state` / `inbox_mark_read` → 只读投影 / 显式已读

用法::

    # 先编出独立测试产物（不安装），再跑
    tools/e2e-app-build.sh --print-path
    python3 tools/e2e-real-app.py --app "/path/to/gmgn radio.app"

    # 让脚本自己编：
    python3 tools/e2e-real-app.py --build

    # 真实生成服务的配置：默认从真实用户目录**只读**复制到测试根（不打印内容）
    python3 tools/e2e-real-app.py --build --prop-config ~/Library/Application\\ Support/ai.gmgn.radio/secrets/prop-generation.json

    # 真实人物 / 动作：只读来源**复制**进测试根（绝不 symlink 到生产；selection 写测试根）
    python3 tools/e2e-real-app.py --build \\
        --avatar-source "$HOME/Library/Application Support/gmgn radio/PresencePackages/pmx.2b-miss-0414-standard" \\
        --motion-source "$HOME/Library/Application Support/gmgn radio/MotionPackages"

测试根默认是 `/tmp/gmgn-e2e-<时间戳>`：taskd 走 AF_UNIX，socket 路径超过
`sockaddr_un.sun_path`（macOS 104 字节）就起不来；驱动器会在启动前拒绝过深的根。
**已有 root 默认拒绝覆盖**：要复用加 `--reuse-root`，要删掉重建加 `--overwrite-root`。

驱动器会真的触发非待机活动（行走 / 跳跃 / 坐下，取当前世界声明的那几项），并在
**运动过程中**连续抓帧、逐帧验"补偿后接触点不低于静止参考"，而不是用 idle 静止
接地冒充"穿地已验"。世界没声明的类别会调一次生产入口拿到具名拒绝码后如实记录，
不记 pass。

电视那一段需要**内置的、钉死 sha256 的** yt-dlp；构建时用
`GMGN_BUNDLE_SCREEN_LINK_HELPER=1 tools/e2e-app-build.sh`（可加 `GMGN_BUNDLE_DENO=1`），
或事后 `python3 tools/bundle-screen-link-helper.py --app "<app>"`。没有内置 helper 时
`play_screen` 会具名报缺 helper，不会被当成通过。

`--video-url` 的默认值是 YouTube VOD。**平台现状（2026-10-03 诊断）**：YouTube 的
签名媒体地址在本机无论是否用 deno/ejs 都返回 403（发生在媒体面，不是解析面），所以
默认值会停在"解析成功但解码 0 帧"。要验收"电视真的有画面"，把 `--video-url` 指向
一条真实可播的公开链接（实测 Twitch 直播可播）：
    python3 tools/e2e-real-app.py --app ... --video-url https://www.twitch.tv/eslcs

**重启恢复不再只看"世界 loaded"**（`restart_recovery` 段）：
  * 物件摆放：重启后从 `read_owned_props` 回读 `is_placed` / `position` / `surface_id` /
    `yaw`，逐项对回重启前的最终摆放事实；
  * 屏幕内容：重启后 `playback_state` 仍须投影出同一块屏，`contentURL` 仍是用户粘的
    **原始页面链接**（无签名媒资地址）；
  * 播放恢复：没有自动续播时**重走生产 `play_screen`**，再验解码帧与 GPU `fragments`
    真的恢复；
  * 足部/姿态（**已按 2026-10-03 用户更正重写语义**）：**先显式区分站姿与坐姿**，绝不
    以 `activeActivity` 为空假定站姿；
      - 显式站姿：测试根 `.selection.json` 只选 `--stand-motion-id`（默认
        `gmgn.motion.bones.idle-loop-pmx`），当前 clip 必须就是它，脚面按双边容差判
        "贴地/浮地"（旧 `min+offset >= rest` 是单边，抓不到浮地）；复制包最后选中的
        `chair-sit` 不得冒充站姿；
      - 坐姿：世界坐姿活动（`chair.sit` / `bunk.rest`）或显式坐姿 clip 才判，**允许脚离地**；
        改判座面支撑（骨盆在循环内稳定）/ 骨盆对齐（相对坐姿入口）/ 身体穿模（最低点不穿地），
        并把 6 帧真实 GPU 回读另存到 `<root>/evidence/restart-frames/` 供人工视觉核验。

**非 HLS 声音对照**（`audio_reference` 段，`--skip-audio-reference` 可关）：在同一块真实
屏幕上放一条**公开、file-based、带音轨**的 mp4，做一次真实 PCM 链采样。HLS 的
`screen_audio` 仍按平台边界 `blocked`（`MTAudioProcessingTap` 不支持清单），**不**改判。
只读确认对照源（不启动 App、不录系统声音）：

    python3 tools/e2e-real-app.py --check-audio-reference        # 默认 W3C Sintel 预告片
    python3 tools/e2e-real-app.py --check-audio-reference \
        --audio-reference-url https://example.com/with-audio.mp4

退出码 0 = 所有**数据链路**断言通过；未通过项在账本里具名。网络/凭据缺失这类
环境问题会如实标记为 `blocked` 而不是 `pass`。

生成步骤只认**真实下载检查完成**（`stage=ready` 且本地模型文件存在），不把
`generated`（服务已生成、待下载检查）当就绪。领取走生产领取门：先等托盘真的
端上产物，再用生产 `start_activity` 让居民走到 `wish_machine.collect`，等
`phase=loop`、距离 ≤ 0.25 m、可领取后调用 `claim_wish_output`，随后轮询
`read_owned_props` 直到物件真的入库、`list_placement_surfaces` 直到承托层真的
加载出来 —— 空列表不算成功。

已有任务要接着验（避免重复生成花费）时用**显式恢复模式**（只复用已有根里的
那条任务，不代表全新生成流程已通过）：

    python3 tools/e2e-real-app.py --app "$APP" --reuse-root --root /tmp/gmgn-e2e-... \
        --existing-wish-id 474AC5DE-3A7D-49A4-88D4-F09902F11DF5 --video-url https://www.twitch.tv/eslcs
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PROP_CONFIG = (
    Path.home()
    / "Library/Application Support/ai.gmgn.radio/secrets/prop-generation.json"
)
DEFAULT_IMAGE = ROOT / "docs/design/gmgn-radio-concept-v1.png"
DEFAULT_VIDEO_URL = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
# 非 HLS 声音对照源：**公开、file-based、带音轨**的 mp4。
#
# 平台边界：`AVPlayerItem.audioMix`（MTAudioProcessingTap 的挂载点）只支持 file-based
# 媒体，HLS/直播清单一律 `unsupported:hls-manifest`（Apple 文档 + 本机实测，见
# `NativeLinkPlayer.install`）。要证明**真实 PCM 采样链**可用，只能用 file-based 源。
# 下面这条是 W3C 的公开 CC 视频（`video/mp4`、`Accept-Ranges: bytes`、AAC 音轨），
# 是主代理在真实 App 里做链采样的对照；它**不**把 HLS 那条 blocked 改成通过。
DEFAULT_AUDIO_REFERENCE_URL = "https://media.w3.org/2010/05/sintel/trailer.mp4"
# **显式**站姿（idle）与坐姿动作。2026-10-03 更正：测试根 `.selection.json` 曾经由
# 复制包顺序决定（第一个包是 chair-sit），于是一个**坐姿** clip 被当成默认站姿去判"脚
# 离地=浮地"。现在测试根只显式选这两个之一：站姿验收要求当前 clip 就是 `STAND_MOTION_ID`，
# 坐姿验收要求当前 clip 是 `SIT_MOTION_ID` 或在跑世界坐姿活动。绝不写生产 selection。
STAND_MOTION_ID = "gmgn.motion.bones.idle-loop-pmx"
SIT_MOTION_ID = "gmgn.motion.bones.chair-sit-loop-pmx"
# 世界声明的坐姿活动 ID（`action: sit`）。坐姿可以经由这些活动入口进入。
SIT_ACTIVITY_IDS = ("chair.sit", "bunk.rest")
# 显式站姿的**浮地**容差（米）：只在当前 clip 确实是 `<STAND_MOTION_ID>` 时使用；脚面
# 高于角色自己的静止脚面超过它才算站姿浮空。它绝不套到坐姿上（坐姿脚离地是本来的姿态）。
RESTART_FLOAT_TOLERANCE_M = 0.05
# 显式站姿的单脚 stance 容差（米）：左右脚各自离静止脚面不能超过它。
RESTART_STANCE_TOLERANCE_M = 0.25
# 坐姿骨盆在循环内的稳定容差（米）：坐着时骨盆不应下沉/弹跳超过它（座面支撑的只读判据）。
SIT_PELVIS_SPAN_TOLERANCE_M = 0.12
# 坐姿骨盆相对坐姿入口（世界根位置）的水平对齐容差（米）：骨盆不能整个滑离座位。
SIT_PELVIS_ALIGNMENT_TOLERANCE_M = 0.60
# 坐姿骨盆必须高于脚面的最小差（米）：证明躯干由座面托着、腿垂在下面。
SIT_PELVIS_ABOVE_FOOT_M = 0.05

# 测试根默认落在 `/tmp` 下**短**路径：taskd 用 AF_UNIX，`sockaddr_un.sun_path` 在
# macOS 上只有 104 字节（含结尾 NUL）。上一轮默认根是仓库内
# `tmp/e2e-real-app/<时间戳>`，socket 路径超过 104 字节 ⇒ taskd 起不来、世界加载失败。
DEFAULT_ROOT_PARENT = Path("/tmp")
DEFAULT_ROOT_PREFIX = "gmgn-e2e-"
# `sun_path` 的总字节数（含结尾 NUL）。可用路径最长 103。
AF_UNIX_SUN_PATH_BYTES = 104
# 接地数值容差（米）：补偿后接触点只要低于静止参考这么多就算穿地。补偿本身是精确的
# （offset >= rest - minimum），所以这里可以收得很紧，5 mm 只留给蒙皮数值噪声。
GROUNDING_TOLERANCE_M = 0.005

# 摆放选点的生产预检上限：候选按"离房间中心由近到远"排序，逐个交给
# `preview_prop_placement`（与落地同一条 `PropPlacementEvaluator`）。真实舱体地面有
# 3,000+ 个单格承托层，靠墙的格心会被真实碰撞判据拒绝；从房间中部往外探，通常前几个
# 就能通过。绝不为了让某一次通过而放宽判据：只有预检放行的位置才会去 apply。
PLACEMENT_PROBE_BUDGET = 160

# taskd 的 socket 相对测试根的路径。**必须**与生产
# `WorldAuthorityEndpoint.taskServiceRoot` / `PropTaskDaemonClient(root:)` 同一口径：
#   <root>/Library/Application Support/gmgn radio/TaskService/taskd.sock
TASKD_SOCKET_RELATIVE = Path(
    "Library/Application Support/gmgn radio/TaskService/taskd.sock"
)
# 人物 / 动作包在测试根里的落点（复制，绝不 symlink 到生产）。
AVATAR_PACKAGES_RELATIVE = Path("Library/Application Support/gmgn radio/PresencePackages")
MOTION_PACKAGES_RELATIVE = Path("Library/Application Support/gmgn radio/MotionPackages")


class E2ERealAppError(RuntimeError):
    """驱动器在启动 App 之前就应该拒绝的配置错误。"""


def default_e2e_root() -> Path:
    """默认测试根：`/tmp/gmgn-e2e-<时间戳>`（短到 AF_UNIX 放得下）。"""
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return DEFAULT_ROOT_PARENT / f"{DEFAULT_ROOT_PREFIX}{stamp}"


def taskd_socket_path(root: Path) -> Path:
    return Path(root) / TASKD_SOCKET_RELATIVE


def validate_taskd_socket_path(root: Path) -> None:
    """拒绝 socket 路径超过 AF_UNIX 上限的测试根，并给出可用的短根建议。"""
    socket = taskd_socket_path(root)
    encoded = len(str(socket).encode("utf-8")) + 1  # 含结尾 NUL
    if encoded > AF_UNIX_SUN_PATH_BYTES:
        raise E2ERealAppError(
            f"测试根太深：taskd socket 路径 {socket} 有 {encoded} 字节，"
            f"超过 AF_UNIX 的 {AF_UNIX_SUN_PATH_BYTES} 字节上限。"
            f"请改用短根，例如 {default_e2e_root()}。"
        )


def assert_test_root_is_not_production(root: Path) -> None:
    """测试根绝不可是真实用户数据目录（或其父目录）。

    `selection.json` 这类文件由 App 写在包根里；如果测试根就是生产
    Application Support，复制/选中就会落到生产。这里在启动前机械拒绝。
    """
    resolved = Path(root).resolve()
    production_roots = []
    for name in ("ai.gmgn.radio", "gmgn radio"):
        production_roots.append((Path.home() / "Library/Application Support" / name).resolve())
    production_support = (Path.home() / "Library/Application Support").resolve()
    if resolved == Path.home().resolve() or resolved == production_support:
        raise E2ERealAppError(f"测试根 {resolved} 是用户数据目录的父级；拒绝把它当测试根。")
    for production in production_roots:
        if resolved == production or production.is_relative_to(resolved):
            raise E2ERealAppError(
                f"测试根 {resolved} 覆盖真实用户目录 {production}；拒绝用它当测试根。"
            )


def reject_symlinks(source: Path) -> None:
    """源里任何 symlink 都拒绝：复制只搬真实文件，绝不放宽现有 symlink 安全检查。"""
    if source.is_symlink():
        raise E2ERealAppError(f"资产源 {source} 是 symlink；拒绝（只接受真实副本来源）。")
    if not source.is_dir():
        return
    for child in source.rglob("*"):
        if child.is_symlink():
            raise E2ERealAppError(
                f"资产源 {source} 里含 symlink：{child}；拒绝复制（不放宽 symlink 安全检查）。"
            )


def discover_packages(source: Path) -> list[tuple[str, Path]]:
    """把来源解析成 `[(包名, 包目录)]`：既支持单个包，也支持包容器目录。"""
    if not source.is_dir():
        raise E2ERealAppError(f"资产源不存在或不是目录：{source}")
    if (source / "manifest.json").is_file():
        return [(source.name, source)]
    packages: list[tuple[str, Path]] = []
    for child in sorted(source.iterdir()):
        if child.name.startswith(".") or not child.is_dir():
            continue
        if (child / "manifest.json").is_file():
            packages.append((child.name, child))
    if not packages:
        raise E2ERealAppError(f"资产源 {source} 里没有带 manifest.json 的包。")
    return packages


def read_source_selection(source: Path) -> str | None:
    selection = source / ".selection.json"
    if not selection.is_file():
        return None
    try:
        payload = json.loads(selection.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    active = payload.get("activeID") if isinstance(payload, dict) else None
    return active if isinstance(active, str) and active else None


def copy_package_source(
    source: Path, destination_root: Path, allow_existing: bool = False,
    preferred_selection: str | None = None,
) -> list[str]:
    """把包**复制**到测试根，并把选中项写进测试根自己的 `.selection.json`。

    - 复制而不是 symlink：生产 PresencePackages/MotionPackages 的目录**绝不**连进
      测试根；App 选中人物/动作时写的是测试根里的 `.selection.json`，不会写生产。
    - 源里的 symlink 一律拒绝。
    - `allow_existing=True`（`--reuse-root`）时，测试根里已有的同名包不重拷，但仍然
      按来源/第一个包写选中项。
    - `preferred_selection` 非空且确实拷进来了时**优先**选它（动作包走这条，显式选站姿，
      不再让复制顺序里的 `chair-sit` 冒充站姿）；它不在包里时如实回落到来源/第一个包，
      由调用方把"显式站姿缺失"记 blocked。
    - 返回复制（或复用）出来的包名列表。
    """
    source = Path(source).expanduser()
    if not source.exists():
        raise E2ERealAppError(f"资产源不存在：{source}")
    reject_symlinks(source)
    packages = discover_packages(source)
    destination_root.mkdir(parents=True, exist_ok=True)
    copied: list[str] = []
    for name, package in packages:
        destination = destination_root / name
        if destination.exists():
            if allow_existing:
                copied.append(name)
                continue
            raise E2ERealAppError(f"测试根里已存在同名包：{destination}（拒绝覆盖）。")
        # symlinks=False 且源已确认无 symlink，所以这里搬的是真实文件副本。
        shutil.copytree(package, destination, symlinks=False)
        copied.append(name)
    selected = read_source_selection(source)
    if preferred_selection and preferred_selection in copied:
        selected = preferred_selection
    if selected not in copied:
        selected = copied[0]
    (destination_root / ".selection.json").write_text(
        json.dumps({"activeID": selected}), encoding="utf-8"
    )
    return copied


def extract_world_tool_result(response: dict) -> dict | None:
    """`tool_call` 回执里世界工具那一层的对象（`{ok, code, message, snapshot}`）。

    注意：`tool()` 在世界工具报错时会把**控制层** `response["ok"]` 也压成 False
    （主代理的可读性修复），所以这里绝不能靠 `response["ok"]` 判有无 —— 直接看
    `response["result"]["result"]` 那一层。错误回执里的 `code` 正是驱动器要的具名原因。
    """
    result = response.get("result")
    if not isinstance(result, dict):
        return None
    inner = result.get("result")
    return inner if isinstance(inner, dict) else None


def extract_world_tool_code(response: dict) -> str | None:
    result = extract_world_tool_result(response)
    if isinstance(result, dict) and isinstance(result.get("code"), str):
        return result["code"]
    error = response.get("error")
    return error if isinstance(error, str) else None


def world_tool_succeeded(response: dict) -> bool:
    if response.get("ok") is not True:
        return False
    return response.get("result", {}).get("isError") is False


def extract_available_activities(response: dict) -> list[dict]:
    result = extract_world_tool_result(response)
    if not isinstance(result, dict):
        return []
    snapshot = result.get("snapshot")
    if not isinstance(snapshot, dict):
        return []
    activities = snapshot.get("activities")
    return [activity for activity in activities if isinstance(activity, dict)] if isinstance(
        activities, list
    ) else []


def same_id(a, b) -> bool:
    """UUID 字符串不分大小写比较（status 回的是大写，命令行常带小写）。"""
    return isinstance(a, str) and isinstance(b, str) and a.lower() == b.lower()


def is_valid_position(value) -> bool:    return (
        isinstance(value, list)
        and len(value) == 3
        and all(isinstance(v, (int, float)) and math.isfinite(float(v)) for v in value)
    )


def motion_grounding_ok(grounding: dict | None, position: list | None) -> bool:
    """一帧运动过程中的接地判据（比静止 status 那条更强）。

    * 位置必须是三维有限值；
    * `contactLiftY + 0.05 >= uncompensatedPenetrationY` 且 lift >= 0（补偿只抬不压）；
    * **补偿后接触点不得低于静止参考**：`minimumContactY + groundingOffsetY + 0.05 >=
      restGlobalReferenceY`。这条能把"offset 算出来了但渲染没施加 / 被清零"的回归钉红 ——
      旧判据只看 lift（由 rest/minimum 独立算出）是自证的，抓不到没施加。
    """
    if not is_valid_position(position) or not isinstance(grounding, dict):
        return False
    minimum = grounding.get("minimumContactY")
    rest = grounding.get("restGlobalReferenceY")
    # 优先用**真实乘进模型变换**的补偿（渲染事实）；缺字段时才回落到策略前的原始值。
    # 这条把"offset 算出来了但渲染没施加 / 被清零"的回归钉红。
    offset = grounding.get("appliedGroundingOffsetY")
    if not isinstance(offset, (int, float)):
        offset = grounding.get("groundingOffsetY")
    lift = grounding.get("contactLiftY")
    uncompensated = grounding.get("uncompensatedPenetrationY")
    numbers = (minimum, rest, offset, lift, uncompensated)
    if not all(isinstance(v, (int, float)) and math.isfinite(float(v)) for v in numbers):
        return False
    if float(lift) + 0.05 < float(uncompensated) or float(lift) < -0.0001:
        return False
    if float(minimum) + float(offset) + GROUNDING_TOLERANCE_M < float(rest):
        return False
    return True


def position_span(positions: list[list]) -> float:
    """一列位置里任意两帧之间的最大欧氏距离（证明角色真的在动）。"""
    valid = [p for p in positions if is_valid_position(p)]
    if len(valid) < 2:
        return 0.0
    best = 0.0
    for index, a in enumerate(valid):
        for b in valid[index + 1:]:
            distance = math.dist([float(v) for v in a], [float(v) for v in b])
            best = max(best, distance)
    return best


def same_position(a, b, tolerance: float = 0.02) -> bool:
    """两个三维位置是否在容差内一致（重启前后摆放位置回读用）。"""
    if not (is_valid_position(a) and is_valid_position(b)):
        return False
    return all(abs(float(x) - float(y)) <= tolerance for x, y in zip(a, b))


def extract_owned_object(response: dict, object_id: str) -> dict | None:
    """`read_owned_props` 回执里指定物件的投影（原样，含 position / surface_id / is_placed）。"""
    inner = response.get("result", {}).get("result") if response.get("ok") else None
    if not isinstance(inner, dict):
        return None
    for obj in inner.get("objects", []) or []:
        if isinstance(obj, dict) and same_id(obj.get("object_id"), object_id):
            return obj
    return None


def extract_number(mapping: dict, key: str) -> float | None:
    value = mapping.get(key) if isinstance(mapping, dict) else None
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def extract_motion_clip(status: dict | None) -> str:
    """`status.avatarMotion.clip`（渲染器真正装载的 clip 名）。读不到给空串，不编造。"""
    if not isinstance(status, dict):
        return ""
    motion = status.get("avatarMotion")
    if not isinstance(motion, dict):
        return ""
    clip = motion.get("clip")
    return clip if isinstance(clip, str) else ""


def motion_role(clip: str | None, stand_motion_id: str, sit_motion_id: str) -> str:
    """把一个 clip 名判成 `stand` / `sit` / `unknown`（**只按已装载的 clip**，不按
    `activeActivity` 猜）。

    用户 2026-10-03 更正的核心：没有活动（`activeActivity` 为空）时显示的可能是**坐姿**
    默认动作，所以"空活动 = 站姿"不成立。角色判定只认：
      * 显式站姿动作 ID，或 idle/stand 语义的名字 ⇒ `stand`；
      * 显式坐姿动作 ID，或 sit / chair / cross-legged / kneeling 语义的名字 ⇒ `sit`；
      * 其它 ⇒ `unknown`（由调用方具名 blocked，不冒充任何一侧）。
    """
    if not clip:
        return "unknown"
    if clip == stand_motion_id:
        return "stand"
    if clip == sit_motion_id:
        return "sit"
    normalized = clip.lower()
    sit_tokens = ("sit", "chair", "cross-legged", "crosslegged", "kneel", "seiza")
    if any(token in normalized for token in sit_tokens):
        return "sit"
    stand_tokens = ("idle", "stand", "natural-idle", "rest")
    if any(token in normalized for token in stand_tokens):
        return "stand"
    return "unknown"


def motion_is_explicit_sit(clip: str | None, active_activity: str | None,
                           sit_motion_id: str) -> bool:
    """坐姿前提：显式坐姿 clip，或正在跑世界声明的坐姿活动。"""
    if isinstance(active_activity, str) and active_activity in SIT_ACTIVITY_IDS:
        return True
    if not clip:
        return False
    if clip == sit_motion_id:
        return True
    normalized = clip.lower()
    return any(
        token in normalized
        for token in ("sit", "chair", "cross-legged", "crosslegged", "kneel", "seiza")
    )


# -- 非 HLS 声音对照源：只读可用性确认 ------------------------------------------

def _http_probe(url: str, timeout: float) -> dict:
    request = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": "gmgn-e2e-readonly/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        headers = {k.lower(): v for k, v in response.headers.items()}
        return {
            "status": int(response.status),
            "contentType": headers.get("content-type", ""),
            "contentLength": headers.get("content-length", ""),
            "acceptRanges": headers.get("accept-ranges", ""),
            "finalURL": response.geturl(),
        }


def _ffprobe_audio_tracks(url: str, timeout: float) -> dict | None:
    """用本机 ffprobe（若可用）只读确认音轨；失败返回 None，交由调用方具名报缺。"""
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return None
    try:
        result = subprocess.run(
            [ffprobe, "-v", "error", "-show_entries",
             "stream=index,codec_type,codec_name", "-of", "json", url],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if result.returncode != 0:
        return None
    try:
        streams = json.loads(result.stdout or "{}").get("streams", [])
    except json.JSONDecodeError:
        return None
    return {
        "streams": streams,
        "audioTracks": [s for s in streams if s.get("codec_type") == "audio"],
        "videoTracks": [s for s in streams if s.get("codec_type") == "video"],
    }


def probe_audio_reference(url: str, timeout: float = 30) -> dict:
    """只读确认 `url` 是公开的 **file-based mp4 且有音轨**（不播放、不录系统声音）。

    返回 `{usable, reason, head, probe}`。`usable` 只在"HTTP 可取 + mp4 + 有音轨"时为真；
    缺 ffprobe / 网络不可达时 `reason` 具名，绝不把"没确认"当"可用"。
    """
    report: dict = {"url": url, "usable": False, "reason": "", "head": {}, "probe": None}
    if not url.lower().split("?")[0].endswith(".mp4"):
        report["reason"] = "URL 不是 .mp4（file-based 媒体才支持 audioMix/tap）"
        return report
    try:
        head = _http_probe(url, timeout)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        report["reason"] = f"HTTP HEAD 失败：{error}"
        return report
    report["head"] = head
    if head.get("status") != 200:
        report["reason"] = f"HTTP 状态 {head.get('status')}（需要 200 公开可取）"
        return report
    content_type = str(head.get("contentType") or "").lower()
    if "mp4" not in content_type and "video/" not in content_type:
        report["reason"] = f"Content-Type 不是 mp4：{content_type or '(空)'}"
        return report
    probe = _ffprobe_audio_tracks(url, timeout)
    report["probe"] = probe
    if probe is None:
        report["reason"] = "缺少可用的 ffprobe，无法只读确认音轨（不当作可用）"
        return report
    if not probe.get("videoTracks"):
        report["reason"] = "没有视频轨"
        return report
    if not probe.get("audioTracks"):
        report["reason"] = "没有音轨（声音对照需要带音轨的 file-based mp4）"
        return report
    audio = probe["audioTracks"][0]
    report["usable"] = True
    report["reason"] = f"公开 file-based mp4，有音轨 {audio.get('codec_name')}"
    return report


# 活动入口要真的触发非待机活动：类别 → 候选活动 ID（按世界声明择优）。
ACTIVITY_CANDIDATES: list[tuple[str, str, list[str]]] = [
    ("行走", "walk", ["home.walk", "dining.walk", "kitchen.walk"]),
    ("跳跃", "jump", ["performance.jumping_jacks"]),
    ("坐下", "sit", ["bunk.rest", "chair.sit"]),
]

# 领取必须真的在跑的**生产**活动（`WishMachineScene.activityID` 的原文）。领取判据
# 要求 `activityID == "wish_machine.collect"`、`phase == "loop"` 且距离 ≤ 0.25 m；
# 驱动器不替它放宽，只负责用生产 `start_activity` 让居民真的走过去。
WISH_MACHINE_COLLECT = "wish_machine.collect"


def choose_activity(candidates: list[str], available: set[str]) -> str | None:
    return next((candidate for candidate in candidates if candidate in available), None)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class Ledger:
    def __init__(self) -> None:
        self.entries: list[dict] = []
        self.step = "boot"
        self.passed = 0
        self.failed = 0
        # 计数属性刻意**不叫** `blocked`：那个名字被下面的 `blocked(...)` 方法占用，
        # 同名会让 `self.blocked("...")` 变成 `0("...")` ⇒ TypeError，驱动器第一步就崩。
        self.blocked_count = 0

    def section(self, name: str) -> None:
        self.step = name
        self.entries.append({"step": name, "kind": "section", "at": now_iso()})
        print(f"\n== {name}")

    def record(self, kind: str, **fields) -> None:
        entry = {"step": self.step, "kind": kind, "at": now_iso()}
        entry.update(fields)
        self.entries.append(entry)

    def check(self, condition: bool, message: str, **evidence) -> bool:
        ok = bool(condition)
        self.record("assert", ok=ok, message=message, **evidence)
        mark = "PASS" if ok else "FAIL"
        print(f"  [{mark}] {message}")
        if ok:
            self.passed += 1
        else:
            self.failed += 1
        return ok

    def blocked(self, message: str, **evidence) -> None:
        self.record("assert", ok=False, blocked=True, message=message, **evidence)
        self.blocked_count += 1
        print(f"  [BLOCKED] {message}")

    def info(self, message: str, **evidence) -> None:
        self.record("info", message=message, **evidence)
        print(f"  [info] {message}")


class AppHost:
    """用 GMGN_E2E_DATA_ROOT 启动一份独立测试产物，并通过文件邮箱下命令。"""

    def __init__(self, app: Path, root: Path, extra_env: dict[str, str] | None = None,
                 log_path: Path | None = None) -> None:
        self.app = app
        self.binary = app / "Contents" / "MacOS" / "gmgn radio"
        self.root = root
        self.control = root / "control"
        self.inbox = self.control / "inbox"
        self.outbox = self.control / "outbox"
        self.evidence = root / "evidence"
        self.log_path = log_path or (root / "app.log")
        self.extra_env = extra_env or {}
        self.process: subprocess.Popen | None = None

    def launch(self, timeout: float = 90) -> None:
        for directory in (self.inbox, self.outbox, self.evidence):
            directory.mkdir(parents=True, exist_ok=True)
        # 崩溃后的 quit 等旧邮箱命令不能在下次启动重放；保留到证据目录。
        stale_mailbox = self.evidence / "stale-mailbox"
        for mailbox in (self.inbox, self.outbox):
            for pending in mailbox.glob("*.json"):
                stale_mailbox.mkdir(parents=True, exist_ok=True)
                pending.rename(stale_mailbox / f"{mailbox.name}-{uuid.uuid4().hex}-{pending.name}")
        ready = self.control / "ready"
        stopped = self.control / "stopped"
        for marker in (ready, stopped):
            marker.unlink(missing_ok=True)
        env = dict(os.environ)
        env.update({
            "GMGN_E2E_DATA_ROOT": str(self.root),
            "CFFIXED_USER_HOME": str(self.root),
            "GMGN_STAGE": "1",
        })
        env.update(self.extra_env)
        self.log_stream = self.log_path.open("ab")
        self.process = subprocess.Popen(
            [str(self.binary)],
            cwd=str(self.app),
            env=env,
            stdout=self.log_stream,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if ready.exists():
                return
            if self.process.poll() is not None:
                raise RuntimeError(
                    f"测试 App 提前退出，退出码 {self.process.returncode}；日志 {self.log_path}"
                )
            time.sleep(0.25)
        raise TimeoutError(f"等待控制面 ready 超时；日志 {self.log_path}")

    def command(self, command: str, params: dict | None = None, timeout: float = 120) -> dict:
        request_id = uuid.uuid4().hex
        request = {"id": request_id, "command": command, "params": params or {}}
        request_url = self.inbox / f"{request_id}.json"
        response_url = self.outbox / f"{request_id}.json"
        tmp = request_url.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
        tmp.rename(request_url)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if response_url.exists():
                try:
                    response = json.loads(response_url.read_text(encoding="utf-8"))
                except json.JSONDecodeError:
                    time.sleep(0.1)
                    continue
                response_url.unlink(missing_ok=True)
                return response
            if self.process is None or self.process.poll() is not None:
                raise RuntimeError("测试 App 在命令执行期间退出")
            time.sleep(0.1)
        raise TimeoutError(f"命令 {command} 超时（{timeout}s）")

    def quit(self, timeout: float = 20) -> None:
        try:
            self.command("quit", timeout=5)
        except (TimeoutError, RuntimeError, OSError):
            pass
        if self.process is not None:
            try:
                self.process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.process.send_signal(signal.SIGTERM)
                try:
                    self.process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=10)
        try:
            self.log_stream.close()
        except Exception:
            pass
        self.process = None


class RealAppE2E:
    def __init__(self, args: argparse.Namespace) -> None:
        self.root = Path(args.root).resolve() if args.root else default_e2e_root()
        self.ledger = Ledger()
        self.args = args
        # 显式站姿 / 坐姿动作：CLI 可覆写，默认 BONES idle / chair-sit。站姿验收只认
        # `stand_motion_id`，坐姿验收只认 `sit_motion_id` 或世界坐姿活动；绝不按
        # `activeActivity` 为空猜站姿。测试根之外的任何 selection 都不写。
        self.stand_motion_id = getattr(args, "stand_motion_id", None) or STAND_MOTION_ID
        self.sit_motion_id = getattr(args, "sit_motion_id", None) or SIT_MOTION_ID
        self.host: AppHost | None = None
        self.app: Path | None = None
        self._read_keys: list[str] = []
        self._inbox_scope_before: tuple[str | None, str | None] | None = None
        self._current_activity: str | None = None
        # 重启恢复的三份**重启前**回读：物件摆放位置、屏幕原始 contentURL、播放度量。
        # 重启后逐项对回，绝不只看"世界 loaded"。
        self._object_id: str | None = None
        self._placement_readback: dict | None = None
        self._screen_readback: dict | None = None
        self._avatar_is_pmx = False

    # -- build ---------------------------------------------------------------

    def ensure_app(self) -> Path:
        if self.args.app:
            app = Path(self.args.app).resolve()
            if not (app / "Contents/MacOS/gmgn radio").exists():
                raise SystemExit(f"--app 不是可运行产物：{app}")
            self.verify_test_bundle(app)
            return app
        if not self.args.build:
            raise SystemExit("需要 --app 或 --build")
        print("[e2e-real-app] 构建独立测试产物（不安装）…")
        result = subprocess.run(
            [str(ROOT / "tools/e2e-app-build.sh"), "--print-path",
             "--configuration", self.args.configuration],
            check=True, capture_output=True, text=True,
        )
        app = Path(result.stdout.strip().splitlines()[-1])
        self.verify_test_bundle(app)
        return app

    @staticmethod
    def verify_test_bundle(app: Path) -> None:
        """拒绝拿生产 bundle id 的产物跑隔离测试：UserDefaults 靠不同 bundle id 分域。"""
        import plistlib
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        bundle_id = info.get("CFBundleIdentifier")
        if bundle_id != "ai.gmgn.radio.e2e":
            raise SystemExit(
                f"产物 bundle id 是 {bundle_id!r}，不是专用测试 id 'ai.gmgn.radio.e2e'；"
                "拒绝在真实偏好域里跑测试。请用 tools/e2e-app-build.sh 构建。"
            )

    # -- root ----------------------------------------------------------------

    def prepare_root(self) -> None:
        try:
            validate_taskd_socket_path(self.root)
            assert_test_root_is_not_production(self.root)
        except E2ERealAppError as error:
            raise SystemExit(str(error)) from error

        # 已有 root **默认拒绝覆盖**：上一轮 driver 会静默 `rmtree`，一条打错的
        # `--root` 就能删掉别人正在跑的测试目录。要复用显式 `--reuse-root`，要重建
        # 显式 `--overwrite-root`。
        if self.root.exists():
            if self.args.reuse_root:
                pass
            elif self.args.overwrite_root:
                shutil.rmtree(self.root)
            else:
                raise SystemExit(
                    f"测试根已存在：{self.root}。默认拒绝覆盖；"
                    f"要复用它加 --reuse-root，要删掉重建加 --overwrite-root。"
                )
        self.root.mkdir(parents=True, exist_ok=True)
        support = self.root / "Library/Application Support"
        support.mkdir(parents=True, exist_ok=True)
        self.ledger.info("测试根已就绪", root=str(self.root),
                         taskdSocket=str(taskd_socket_path(self.root)))
        # 真实生成服务的配置**真的注入**到 App 显式读取的那条路径下：
        #   <root>/Library/Application Support/ai.gmgn.radio/secrets/prop-generation.json
        # App 侧 `PropGenerationConfigurationStore` 在 E2E 下读的正是这个根（显式 root
        # 注入，不依赖 CFFIXED_USER_HOME）；这里只做复制，**不读取、不打印内容**，
        # 落盘后立刻收成 0600。源路径与目标路径相同（`--root` 指向真实生产根）时拒绝，
        # 绝不把生产配置覆盖成测试态。
        config = Path(self.args.prop_config).expanduser() if self.args.prop_config else DEFAULT_PROP_CONFIG
        destination = support / "ai.gmgn.radio/secrets/prop-generation.json"
        self._production_config_injected = False
        if config.is_file():
            if config.resolve() == destination.resolve():
                raise SystemExit(
                    f"--prop-config 指向测试根本身（{config}）；拒绝把生产配置当成测试输入。"
                )
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(config, destination)
            os.chmod(destination, 0o600)
            self._production_config_injected = True
            self.ledger.info(
                "生成服务配置已注入测试根（内容不打印；权限 0600）",
                bytes=destination.stat().st_size,
                relative=str(destination.relative_to(self.root)),
            )
        else:
            self.ledger.info("生成服务配置不存在；生成步骤会如实标记 blocked", path=str(config))
        self.inject_packages()

    def inject_packages(self) -> None:
        """把 `--avatar-source` / `--motion-source` 的包**复制**进测试根。

        绝不 symlink 到生产 PresencePackages/MotionPackages：复制保证 App 选中人物/动作
        时写的 `.selection.json` 落在测试根，生产 selection 一个字节都不动。
        来源只读；源里的 symlink 直接拒绝。

        **动作包额外一步**：复制完成后把测试根选中项显式写成 `--stand-motion-id`。上一轮
        按复制顺序选，`chair-sit` 排在 `idle-loop` 前面，于是一个坐姿 clip 被当成默认站姿
        去判"脚离地=浮地"。这里显式选站姿；缺包就具名 blocked，绝不用别的动作冒充。
        """
        for kind, sources, relative, preferred in (
            ("人物", self.args.avatar_source, AVATAR_PACKAGES_RELATIVE, None),
            ("动作", self.args.motion_source, MOTION_PACKAGES_RELATIVE, self.stand_motion_id),
        ):
            if not sources:
                continue
            destination_root = self.root / relative
            for source in sources:
                try:
                    copied = copy_package_source(
                        Path(source), destination_root,
                        allow_existing=self.args.reuse_root,
                        preferred_selection=preferred,
                    )
                except E2ERealAppError as error:
                    raise SystemExit(str(error)) from error
                self.ledger.info(
                    f"{kind}包已复制到测试根（源只读；选中项写入测试根）",
                    source=str(Path(source).expanduser()),
                    destination=str(destination_root.relative_to(self.root)),
                    packages=copied,
                    selected=read_source_selection(Path(source).expanduser()),
                )
            if kind == "动作":
                self.select_explicit_stand_motion(destination_root)

    def select_explicit_stand_motion(self, motion_root: Path) -> None:
        """把测试根的站姿选中项**显式**写成 `--stand-motion-id`（只写测试根）。

        多个 `--motion-source` 时最后一次复制会把选中项写成"来源里第一个包"；这里在全部
        复制完成后统一覆盖成显式站姿，顺序不再影响语义。包不存在时具名 blocked。
        """
        stand_id = self.stand_motion_id
        package = motion_root / stand_id
        available = (
            sorted(entry.name for entry in motion_root.iterdir() if entry.is_dir())
            if motion_root.exists() else []
        )
        if not package.is_dir():
            self.ledger.blocked(
                f"测试根动作包缺少显式站姿 {stand_id}；站姿贴地无法验证"
                "（拒绝用复制顺序里最后的动作冒充站姿）",
                available=available,
            )
            return
        (motion_root / ".selection.json").write_text(
            json.dumps({"activeID": stand_id}), encoding="utf-8")
        selection = motion_root / ".selection.json"
        try:
            relative = str(selection.relative_to(self.root))
        except ValueError:
            relative = str(selection)
        self.ledger.info(
            "测试根动作选中项已显式写成站姿（生产 selection 一个字节未动）",
            activeID=stand_id,
            relative=relative,
            available=available,
        )

    # -- steps ---------------------------------------------------------------

    def validate_mode(self) -> None:
        """恢复模式只用于"接着验已有任务"：必须复用已有根（那里才有那条任务），
        不许拿新根/覆盖根跑，否则会被当成"全新生成流程已通过"。"""
        if self.args.existing_wish_id and (not self.args.reuse_root or self.args.overwrite_root):
            raise SystemExit(
                "--existing-wish-id 只用于接着验已有任务：必须与 --reuse-root 同用，"
                "且不能与 --overwrite-root 同用（否则任务不存在，也不该重新生成）。"
            )

    def run(self) -> int:
        self.validate_mode()
        self.app = self.ensure_app()
        self.prepare_root()
        self.ledger.record("app", path=str(self.app), root=str(self.root))
        self._production_before = self.production_fingerprint()
        self.host = AppHost(self.app, self.root)
        try:
            self.run_session()
        finally:
            if self.host is not None and self.host.process is not None:
                self.ledger.section("shutdown")
                self.host.quit()
        self._production_after = self.production_fingerprint()
        self.ledger.section("isolation")
        self.ledger.check(
            self._production_before == self._production_after,
            "端到端运行没有写真实用户 Application Support",
            before=self._production_before,
            after=self._production_after,
        )
        return self.finish()

    # -- production isolation guard -----------------------------------------

    @staticmethod
    def production_fingerprint() -> dict[str, str]:
        """真实用户 Application Support 下关键路径的指纹。

        只读 `mtime_ns` 与条目数/size：E2E 若回落写生产（新增 taskd socket、
        wishes.json、世界预像、**人物/动作 selection**……），目录 mtime 必然变。
        真实配置的**读取**不动 mtime，所以这条判据不会把"只读复用配置"误判成写生产。

        人物/动作的 `.selection.json` 单独入指纹：写它只改 `PresencePackages` /
        `MotionPackages` 子目录的 mtime，不会动 `gmgn radio` 根目录的 mtime ——
        只看根目录会把"借测试根写生产 selection"漏过去。
        """
        base = Path.home() / "Library/Application Support"
        fingerprint: dict[str, str] = {}
        candidates = [
            base / "ai.gmgn.radio",
            base / "gmgn radio",
            base / "gmgn radio" / "PresencePackages",
            base / "gmgn radio" / "PresencePackages" / ".selection.json",
            base / "gmgn radio" / "MotionPackages",
            base / "gmgn radio" / "MotionPackages" / ".selection.json",
        ]
        for path in candidates:
            key = str(path.relative_to(base))
            try:
                stat = path.stat()
                fingerprint[key] = f"{stat.st_mtime_ns}:{stat.st_size}"
            except FileNotFoundError:
                fingerprint[key] = "absent"
            except OSError as error:
                fingerprint[key] = f"oserror:{error.errno}"
        return fingerprint

    def run_session(self) -> None:
        assert self.host is not None
        self.ledger.section("launch")
        self.host.launch(timeout=self.args.timeout)
        ping = self.host.command("ping")
        self.ledger.check(ping.get("ok") is True, "控制面可通信")

        self.ledger.section("status")
        status = self.wait_status(lambda s: s.get("livingWorldLoaded") and s.get("stageVisible"),
                                  timeout=self.args.timeout)
        self.ledger.check(bool(status.get("livingWorldLoaded")), "生活世界已加载",
                          status=status)
        self.ledger.check(status.get("stageVisible") is True, "舞台窗口已呈现", status=status)
        context = {
            "worldID": status.get("selectedWorldID") or status.get("residentWorldID"),
            "residentScope": status.get("residentScope"),
        }
        self.ledger.check(bool(context["worldID"]), "选中的世界非空", context=context)
        status = self.wait_grounding_consistent("启动后", timeout=min(self.args.timeout, 20)) or status
        self.check_avatar_grounding(status, "启动后")
        if self.args.avatar_source:
            # 驱动器显式复制了 PMX 人物：确认被选中的**不是**内置光球，而是真的 PMX。
            avatar_format = str(status.get("avatarFormat") or "").lower()
            self._avatar_is_pmx = avatar_format == "pmx"
            self.ledger.check(
                bool(status.get("avatarID")) and avatar_format == "pmx",
                f"复制进测试根的 PMX 人物真的被选中（avatarID={status.get('avatarID')}）",
                avatarID=status.get("avatarID"), avatarFormat=status.get("avatarFormat"),
            )

        if self.args.motion_source:
            # **显式站姿 / 坐姿分开两段**：测试根已经在 inject_packages 里显式选了 idle，
            # 这里先核对站姿贴地，再把持久动作显式切到凳上坐姿、按坐姿语义判支撑/对齐/穿模
            # （允许脚离地），最后切回站姿。坐姿活动判据在活动/重启段再走一遍。
            self.verify_pose_stand(status)
            self.verify_pose_sit(status)

        self.ledger.section("metal_frames")
        frames = self.host.command("capture_frames", {"count": 6, "intervalMs": 150},
                                   timeout=self.args.timeout)
        captured = frames.get("result", {}).get("frames", []) if frames.get("ok") else []
        hashes = {frame.get("sha256") for frame in captured}
        self.ledger.check(len(captured) >= 4, f"抓到至少 4 帧真实 GPU 回读（实际 {len(captured)}）",
                          frames=frames)
        self.ledger.check(len(hashes) >= 2, f"连续帧确实在变（{len(hashes)} 个不同摘要）",
                          hashes=sorted(h for h in hashes if h)[:8])
        frame_indices = [f.get("frameIndex") for f in captured if isinstance(f.get("frameIndex"), int)]
        self.ledger.check(
            len(frame_indices) >= 4 and all(b > a for a, b in zip(frame_indices, frame_indices[1:])),
            "帧序号严格递增（连续画面，不是同一帧重复）",
            frameIndices=frame_indices,
        )
        captured_at = [f.get("capturedAt") for f in captured
                       if isinstance(f.get("capturedAt"), (int, float))]
        span = (max(captured_at) - min(captured_at)) if len(captured_at) >= 2 else 0.0
        self.ledger.check(
            span >= 0.3,
            f"抓帧跨越真实时间（{span:.3f}s，不是一次性快照）",
            span=span,
        )

        # 真实活动入口：**先**跑这一段（排在生成之前），这样即使生成被环境 blocked，
        # "人物在真实运动中没有穿地"仍然被验过，不会退化成只有 idle 接地。
        self.run_activity_motion()

        self.ledger.section("wish_generation")
        if self.args.existing_wish_id:
            # 显式恢复模式：只接着验已有任务，**不生成、不消耗新授权**。
            job = self.resolve_existing_wish(self.args.existing_wish_id)
        else:
            authorization = self.authorize_wish()
            job = self.submit_wish(authorization)
        if job is None:
            self.ledger.blocked("真实生成链路未完成（配置/网络/凭据），后续摆放与播放依赖它")
            return
        self.ledger.check(
            bool(job.get("objectID")) and self.wish_download_checked(job),
            "生成任务产出物件编号且已完成真实下载检查",
            job=job)
        object_id = job.get("objectID")

        self.ledger.section("claim_and_placement")
        self.run_claim_and_placement(job)
        object_id = job.get("objectID")

        self.ledger.section("video_playback")
        if object_id:
            play = self.tool("play_screen", {"object_id": object_id,
                                             "url": self.args.video_url})
            self.ledger.record("play_screen", result=play)
            self.ledger.check(play.get("ok") is True, "电视播放工具被接受", result=play)
            # 命令被接受**不算通过**：必须等到这块屏真的在放，并且解码帧数在涨、
            # 播放时间在前进。落盘的 content_url 必须还是用户粘的**原始页面链接**。
            screen = self.wait_screen_playing(object_id, timeout=self.args.timeout)
            self.ledger.check(screen is not None, "电视进入播放态（真实解码，不是命令成功）",
                              screen=screen)
            if screen is not None:
                content_url = str(screen.get("contentURL") or "")
                signed_markers = ("googlevideo", "expire=", "token=", "signature=", "&sig=")
                self.ledger.check(
                    content_url == self.args.video_url
                    and not any(marker in content_url for marker in signed_markers),
                    "落盘内容仍是原始页面链接（没有签名媒资地址）",
                    contentURL=content_url,
                )
                first = screen.get("nativeLink") or {}
                decoded_before = int(first.get("decodedFrames") or 0)
                seconds_before = first.get("currentSeconds")
                self.ledger.check(decoded_before >= 2,
                                  f"原生播放器真的解出了帧（decodedFrames={decoded_before}）",
                                  nativeLink=first)
                self.ledger.check(
                    int(first.get("pixelWidth") or 0) > 0 and int(first.get("pixelHeight") or 0) > 0,
                    "解码帧有真实像素尺寸", nativeLink=first)
                time.sleep(2.0)
                later = self.wait_screen_playing(object_id, timeout=10) or {}
                second = later.get("nativeLink") or {}
                decoded_after = int(second.get("decodedFrames") or 0)
                seconds_after = second.get("currentSeconds")
                self.ledger.check(decoded_after > decoded_before,
                                  f"播放中解码帧数持续增长（{decoded_before} → {decoded_after}）",
                                  nativeLink=second)
                if not second.get("isLive"):
                    advanced = (float(seconds_after or 0.0) - float(seconds_before or 0.0))
                    self.ledger.check(advanced >= 0.5,
                                      f"播放时间前进不少于 0.5s（{advanced:.3f}s）",
                                      before=seconds_before, after=seconds_after)
                # **画面**判据：解码统计在涨不等于电视上有画面。渲染器必须真的消费
                # `WorldScreenNativeVideoRegistry` 并把视频纹理编码进场景（drawPasses /
                # encodedQuads），而且真的有片元通过深度测试写进 drawable（fragments，
                # GPU 可见性查询）。缺任何一个 = 电视没画面。
                render = self.wait_screen_render(timeout=min(self.args.timeout, 30))
                self.ledger.check(
                    bool(render) and int(render.get("drawPasses") or 0) > 0,
                    "原生视频帧被渲染器真的画进场景（drawPasses>0，不是解码统计）",
                    screenVideo=render)
                if render:
                    self.ledger.check(
                        int(render.get("encodedQuads") or 0) > 0,
                        "渲染器编码了至少一个电视四边形", screenVideo=render)
                    self.ledger.check(
                        int(render.get("fragments") or 0) > 0,
                        "电视画面真的有像素通过深度测试（fragments>0）", screenVideo=render)
                    self.ledger.info(
                        "屏幕画面渲染证据："
                        f"drawPasses={render.get('drawPasses')} "
                        f"encodedQuads={render.get('encodedQuads')} "
                        f"fragments={render.get('fragments')} "
                        f"lastObjectIDs={render.get('lastObjectIDs')}",
                        screenVideo=render)
                # 重启前的屏幕回读：原始 contentURL + 真实播放度量。重启后逐项对回。
                self._screen_readback = {
                    "objectID": object_id,
                    "contentURL": content_url,
                    "decodedFrames": decoded_after,
                    "drawPasses": int((render or {}).get("drawPasses") or 0),
                    "fragments": int((render or {}).get("fragments") or 0),
                }
                self.check_screen_audio(object_id, label="电视", section=True)
        else:
            self.ledger.blocked("没有物件可用于电视播放")

        self.ledger.section("inbox_read")
        inbox = self.host.command("inbox_state")
        inbox_result = inbox.get("result", {}) if inbox.get("ok") else {}
        entries = inbox_result.get("entries", [])
        self.ledger.check(inbox.get("ok") is True, "收件箱状态可读", result=inbox)
        # 作用域是持久化记录的一部分：重启前记下这一份，重启后要逐字对得上。
        self._inbox_scope_before = (
            inbox_result.get("worldID"), inbox_result.get("residentScope"))
        unread = [e for e in entries if not e.get("isRead")]
        read_keys: list[str] = []
        self._unread_after_mark: int | None = None
        if not entries:
            self.ledger.blocked("收件箱里没有任何通知，无法验证「已读 + 重启保存」")
        elif not unread:
            # 全部已读时先制造一条未读：重启持久化判据必须有东西可验，不能空跑通过。
            self.ledger.blocked("收件箱没有未读通知，无法验证状态翻转与重启保存")
        else:
            target = unread[0]
            unread_before = int(inbox.get("result", {}).get("unread") or len(unread))
            marked = self.host.command("inbox_mark_read", {"taskKey": target.get("taskKey")})
            self.ledger.check(marked.get("ok") is True and
                              marked.get("result", {}).get("markedRead") is True,
                              "通知已按显式已读落库", result=marked)
            after_mark = self.host.command("inbox_state").get("result", {})
            after_map = {e.get("taskKey"): e for e in after_mark.get("entries", [])}
            unread_after = int(after_mark.get("unread") or 0)
            self._unread_after_mark = unread_after
            self.ledger.check(
                after_map.get(target.get("taskKey"), {}).get("isRead") is True,
                "被标记的那条在重启前已是已读", entry=after_map.get(target.get("taskKey")))
            self.ledger.check(
                unread_after == unread_before - 1,
                f"未读数减少 1（{unread_before} → {unread_after}）",
                before=unread_before, after=unread_after)
            read_keys = [target.get("taskKey")]
            # 同一条再标记一次必须是幂等的（同 id 同状态，不翻回去）。
            again = self.host.command("inbox_mark_read", {"taskKey": target.get("taskKey")})
            self.ledger.check(again.get("ok") is True,
                              "同一通知重复标记是幂等的", result=again)
        self._read_keys = [key for key in read_keys if key]

        self.ledger.section("restart_recovery")
        self.restart()
        assert self.host is not None
        # **加载时序**：重启后先等世界真的装回来，再读收件箱 —— 持久化恢复发生在
        # 世界作用域确定之后。上一轮一重启就立刻读，把"还没恢复"当成"记录丢了"。
        status_after = self.wait_status(
            lambda s: s.get("livingWorldLoaded") and s.get("stageVisible"),
            timeout=self.args.timeout)
        self.ledger.check(bool(status_after.get("livingWorldLoaded")),
                          "重启后生活世界重新加载", status=status_after)
        after = self.host.command("inbox_state").get("result", {})
        self.ledger.check(
            after.get("restored") is True,
            "重启后收件箱先恢复持久层再投影（不是读内存空表）",
            scope=(after.get("worldID"), after.get("residentScope")))
        if self._inbox_scope_before is not None:
            after_scope = (after.get("worldID"), after.get("residentScope"))
            self.ledger.check(
                after_scope == self._inbox_scope_before,
                "重启前后收件箱作用域一致（worldID + residentScope）",
                before=self._inbox_scope_before, after=after_scope)
        after_entries = after.get("entries", [])
        after_map = {e.get("taskKey"): e for e in after_entries}
        self.ledger.check(
            bool(self._read_keys),
            "重启持久化判据有可验证的已读通知（不能空跑通过）",
            readKeys=self._read_keys)
        # **空列表不算成功**：必须逐条把重启前标记的那条原样读回来。
        for key in self._read_keys:
            entry = after_map.get(key)
            self.ledger.check(entry is not None and entry.get("isRead") is True,
                              f"重启后通知仍为已读：{key}", entry=entry)
        if self._unread_after_mark is not None:
            self.ledger.check(
                int(after.get("unread") or 0) == self._unread_after_mark,
                f"重启后未读数与已读时的存档一致（{self._unread_after_mark}）",
                unread=after.get("unread"))
        # 角色地面接触与空间位置：重启后位置必须是有限值，且脚底不低于地面。
        # 先等补偿在真实渲染帧上收敛，再断言（见 `wait_grounding_consistent`）。
        status_after = self.wait_grounding_consistent(
            "重启后", timeout=min(self.args.timeout, 30)) or status_after
        self.check_avatar_grounding(status_after, "重启后")

        # 重启恢复不能只看"世界 loaded"：物件摆放位置、屏幕原始 contentURL、真实播放
        # 恢复都要逐项回读对回；足部/姿态要世界坐标诊断 + 真实 GPU 抓帧供人工核验。
        self.verify_restart_placement_readback()
        self.verify_restart_screen_readback()
        status_after = self.verify_restart_foot_pose(status_after) or status_after

        # 非 HLS 声音对照：HLS 那条 `screen_audio` 仍然 blocked（平台 tap 边界，不改判）。
        # 这段只在主代理显式要真实链采样时跑（默认跑；`--skip-audio-reference` 可关）。
        if not self.args.skip_audio_reference:
            if self._object_id:
                self.verify_audio_reference(self._object_id)
            else:
                self.ledger.section("audio_reference")
                self.ledger.blocked("没有已入库物件，非 HLS 对照无法在真实屏幕上采样")

        # 真实聊天回合提交链：放在最后，避免真实模型可能发出的工具调用干扰前面的
        # 世界/电视断言。它验证的是「生产提交门 → 对话服务」这条真实链路，不是
        # 直接 tool_call 生成工具（后者已经用过，只算生成通道）。
        if not self.args.skip_chat_turn:
            self.verify_chat_turn()

    # -- 重启恢复：物件 / 屏幕 / 播放 / 足部姿态 --------------------------------

    def verify_restart_placement_readback(self) -> None:
        """重启后**物件摆放位置**真的从持久层读回来，并与重启前逐字段一致。

        只断言"世界 loaded"回答不了"摆出去的物件没有复位/消失/被挂到手上"。判据全部读
        `read_owned_props` 的生产回执（`is_placed` / `position` / `surface_id` / `yaw`），
        没有回读就具名 blocked，绝不空跑通过。
        """
        assert self.host is not None
        object_id = self._object_id
        before = self._placement_readback or {}
        if not object_id or not before:
            self.ledger.blocked(
                "重启前没有可用的摆放回读，重启物件摆放恢复未验证",
                objectID=object_id, before=before)
            return
        owned = self.tool_quiet("read_owned_props", {})
        after = extract_owned_object(owned, object_id)
        self.ledger.check(
            after is not None,
            f"重启后库存仍含该物件（read_owned_props 含 {object_id}）",
            objectID=object_id, owned=owned)
        if after is None:
            return
        self.ledger.check(after.get("is_placed") is True,
                          "重启后物件仍处于摆放态（不是只记在库存里）", object=after)
        self.ledger.check(after.get("is_held") is not True,
                          "重启后物件没有被误挂到居民手上", object=after)
        self.ledger.check(
            same_position(after.get("position"), before.get("position")),
            f"重启后摆放位置与重启前一致"
            f"（{before.get('position')} → {after.get('position')}）",
            before=before.get("position"), after=after.get("position"))
        if before.get("surface_id"):
            self.ledger.check(
                after.get("surface_id") == before.get("surface_id"),
                f"重启后承托面与重启前一致（{before.get('surface_id')}）",
                beforeSurface=before.get("surface_id"),
                afterSurface=after.get("surface_id"))
        before_yaw = before.get("yaw")
        after_yaw = after.get("yaw")
        if isinstance(before_yaw, (int, float)) and isinstance(after_yaw, (int, float)):
            self.ledger.check(
                abs(float(after_yaw) - float(before_yaw)) <= 0.02,
                f"重启后物件朝向与重启前一致（{float(before_yaw):.4f} → {float(after_yaw):.4f} rad）",
                beforeYaw=before_yaw, afterYaw=after_yaw)

    def wait_restart_screen(self, object_id: str, timeout: float) -> dict | None:
        """轮询 `playback_state`，等重启后这块屏重新出现在世界投影里（不看是否在播）。"""
        assert self.host is not None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.host.command("playback_state")
            result = response.get("result", {}) if response.get("ok") else {}
            for screen in result.get("screens", []):
                if screen.get("objectID") == object_id:
                    return screen
            time.sleep(0.5)
        return None

    def verify_restart_screen_readback(self) -> None:
        """重启后**屏幕原始 contentURL** 与真实播放恢复都回读对回。

        `listScreens()` 重启后必须仍投影出这块屏、`contentURL` 仍是用户粘的原始页面链接
        （没有签名媒资地址）。播放不会凭空续上时，**重走生产 `play_screen`** 再验解码帧
        与 GPU 片元真的恢复；不把"URL 还记得"当成"画面恢复了"。
        """
        assert self.host is not None
        before = self._screen_readback or {}
        object_id = self._object_id
        if not object_id or not before:
            self.ledger.blocked("重启前没有可用的电视回读，重启屏幕/播放恢复未验证",
                                objectID=object_id, before=before)
            return
        # 屏幕投影随世界恢复出现，晚一两拍是正常的；先等它出现再断言（别把恢复中的空窗
        # 当成"屏幕丢了"）。
        screen = self.wait_restart_screen(object_id, timeout=min(self.args.timeout, 30))
        self.ledger.check(screen is not None,
                          "重启后电视屏幕仍在世界投影里（不是丢失）", objectID=object_id)
        if screen is None:
            return
        content_url = str(screen.get("contentURL") or "")
        self.ledger.check(
            content_url == before.get("contentURL"),
            "重启后屏幕内容仍是重启前的原始页面链接",
            before=before.get("contentURL"), after=content_url)
        signed_markers = ("googlevideo", "expire=", "token=", "signature=", "&sig=")
        self.ledger.check(
            bool(content_url) and not any(marker in content_url for marker in signed_markers),
            "重启后落盘内容仍是原始页面链接（没有签名媒资地址）",
            contentURL=content_url)
        native = screen.get("nativeLink") or {}
        auto_resumed = (screen.get("surface") == "playing"
                        and int(native.get("decodedFrames") or 0) >= 2)
        if auto_resumed:
            self.ledger.info("重启后原生播放已自动恢复", nativeLink=native)
        else:
            resumed = self.tool("play_screen",
                                {"object_id": object_id, "url": before.get("contentURL")})
            self.ledger.check(resumed.get("ok") is True,
                              "重启后经生产播放入口重新起播被接受", result=resumed)
            screen = self.wait_screen_playing(object_id, timeout=self.args.timeout)
        self.ledger.check(screen is not None,
                          "重启后电视播放真的恢复（真实解码，不是命令成功）", screen=screen)
        if screen is None:
            return
        native = screen.get("nativeLink") or {}
        decoded_before = int(before.get("decodedFrames") or 0)
        decoded_after = int(native.get("decodedFrames") or 0)
        self.ledger.check(
            decoded_after >= 2,
            f"重启后解码帧数可读且已恢复（重启前 {decoded_before} → 重启后 {decoded_after}）",
            nativeLink=native)
        render = self.wait_screen_render(timeout=min(self.args.timeout, 30))
        self.ledger.check(
            bool(render) and int(render.get("fragments") or 0) > 0,
            "重启后电视画面重新有像素通过深度测试（fragments>0）", screenVideo=render)

    def wait_standing_settled(self, label: str, timeout: float) -> dict:
        """等**显式站姿**在世界坐标上收敛：clip 是站姿动作，且脚面落在静止脚面附近。

        与旧 `wait_restart_foot_settled` 的区别：旧版不判 clip，坐姿也能在"脚面=静止脚面"
        的过渡帧上瞬间命中，随后拿后面的坐姿帧判浮地 —— 那正是被用户纠正的错误前提。
        这里先要求 clip 就是 `--stand-motion-id`，并在**至少两个不同的真实渲染帧**上看到
        脚面贴地才返回；clip 读不到 / 不是站姿时不假装收敛，超时返回最后读数，由调用方
        具名 blocked。
        """
        assert self.host is not None
        deadline = time.monotonic() + timeout
        last: dict = {}
        started = time.monotonic()
        rendered_frames: set[int] = set()
        while time.monotonic() < deadline:
            response = self.host.command("status")
            status = response.get("result", {}) if response.get("ok") else {}
            last = status
            clip = extract_motion_clip(status)
            grounding = status.get("avatarGrounding")
            if clip == self.stand_motion_id and isinstance(grounding, dict):
                sole = extract_number(grounding, "lowestSoleWorldY")
                plane = extract_number(grounding, "restFootPlaneWorldY")
                frames = grounding.get("renderedAvatarFrameCount")
                if sole is not None and plane is not None and isinstance(frames, int):
                    rendered_frames.add(frames)
                    if (abs(sole - plane) <= RESTART_FLOAT_TOLERANCE_M
                            and len(rendered_frames) >= 2):
                        settled = dict(status)
                        settled["footSettleSeconds"] = time.monotonic() - started
                        return settled
            time.sleep(0.25)
        last = dict(last)
        last["footSettleSeconds"] = time.monotonic() - started
        return last

    @staticmethod
    def pose_world_fields(status: dict) -> dict:
        """世界坐标姿态读数（脚面 / 全身最低点 / 静止脚面 / 骨盆）的原样投影。"""
        grounding = status.get("avatarGrounding") if isinstance(status, dict) else None
        grounding = grounding if isinstance(grounding, dict) else {}
        return {
            "lowestSoleWorldY": extract_number(grounding, "lowestSoleWorldY"),
            "lowestContactWorldY": extract_number(grounding, "lowestContactWorldY"),
            "restFootPlaneWorldY": extract_number(grounding, "restFootPlaneWorldY"),
            "leftSoleWorldY": extract_number(grounding, "leftSoleWorldY"),
            "rightSoleWorldY": extract_number(grounding, "rightSoleWorldY"),
            "pelvisWorldX": extract_number(grounding, "pelvisWorldX"),
            "pelvisWorldY": extract_number(grounding, "pelvisWorldY"),
            "pelvisWorldZ": extract_number(grounding, "pelvisWorldZ"),
        }

    def check_standing_feet(self, status: dict, label: str) -> bool:
        """**显式站姿**的贴地判据（双边）。

        只在当前 clip 就是 `--stand-motion-id` 时成立：复制包最后选中的 `chair-sit` 不能
        冒充站姿，`activeActivity` 为空也不能推断站姿。clip 不符 / 诊断缺失时具名 blocked，
        返回是否通过。
        """
        clip = extract_motion_clip(status)
        if clip != self.stand_motion_id:
            self.ledger.blocked(
                f"{label}未装载显式站姿动作，站姿贴地未验证"
                f"（clip={clip or 'none'}，期望 {self.stand_motion_id}；"
                "不以 activeActivity 为空假定站姿）",
                clip=clip, activeActivity=status.get("activeActivity"),
                standMotionID=self.stand_motion_id)
            return False
        avatar_format = str(status.get("avatarFormat") or "").lower()
        if avatar_format and avatar_format != "pmx":
            self.ledger.blocked(
                f"{label}当前人物不是 PMX，世界坐标足部诊断不可用（站姿贴地未验证）",
                avatarFormat=status.get("avatarFormat"))
            return False
        fields = self.pose_world_fields(status)
        core = ("lowestSoleWorldY", "lowestContactWorldY", "restFootPlaneWorldY")
        if not all(fields[key] is not None for key in core):
            self.ledger.check(
                False,
                f"{label}世界坐标足部/接触诊断可读（脚面 + 全身最低点 + 静止脚面）",
                worldGrounding=fields, avatarGrounding=status.get("avatarGrounding"))
            return False
        sole = float(fields["lowestSoleWorldY"])
        contact = float(fields["lowestContactWorldY"])
        plane = float(fields["restFootPlaneWorldY"])
        sole_clearance = sole - plane
        contact_clearance = contact - plane
        sided = (fields["leftSoleWorldY"] is not None
                 and fields["rightSoleWorldY"] is not None)
        left_clearance = float(fields["leftSoleWorldY"]) - plane if sided else None
        right_clearance = float(fields["rightSoleWorldY"]) - plane if sided else None
        self.ledger.info(
            f"{label}显式站姿世界坐标足部诊断（{status.get('footSettleSeconds', 0):.2f}s 收敛）",
            clip=clip, soleClearance=sole_clearance, contactClearance=contact_clearance,
            leftClearance=left_clearance, rightClearance=right_clearance,
            worldGrounding=fields)
        if sided:
            # 双脚都不能穿地（对静止/运动都成立，属强判据）。
            self.ledger.check(
                min(left_clearance, right_clearance) >= -GROUNDING_TOLERANCE_M,
                f"{label}双脚都没有穿地（左 {left_clearance:.4f} m / 右 {right_clearance:.4f} m）",
                leftClearance=left_clearance, rightClearance=right_clearance)
        else:
            self.ledger.info(f"{label}左右脚分侧诊断不可用（骨骼名未分侧），只按整体脚面判")
        # 显式站姿：脚面必须**贴地**，不能悬空（旧单边判据抓不到的那一类）。
        self.ledger.check(
            -GROUNDING_TOLERANCE_M <= sole_clearance <= RESTART_FLOAT_TOLERANCE_M,
            f"{label}脚面贴地（离地 {sole_clearance:.4f} m，"
            f"容差 -{GROUNDING_TOLERANCE_M}…+{RESTART_FLOAT_TOLERANCE_M}）",
            clip=clip, soleClearance=sole_clearance, worldGrounding=fields)
        self.ledger.check(
            -GROUNDING_TOLERANCE_M <= contact_clearance <= RESTART_FLOAT_TOLERANCE_M,
            f"{label}全身最低点贴地（离地 {contact_clearance:.4f} m）",
            clip=clip, contactClearance=contact_clearance, worldGrounding=fields)
        self.ledger.check(
            abs(contact - sole) <= RESTART_STANCE_TOLERANCE_M,
            f"{label}全身接触探针与脚底一致（差 {abs(contact - sole):.4f} m，"
            f"容差 {RESTART_STANCE_TOLERANCE_M}）",
            contactWorldY=contact, soleWorldY=sole)
        return True

    def check_sit_support(self, label: str, status: dict,
                          frames: list[dict] | None = None) -> bool:
        """**坐姿**判据：允许脚离地，改判座面支撑 / 骨盆对齐 / 身体穿模。

        前提（由 `motion_is_explicit_sit`）：当前 clip 是显式坐姿动作，或正在跑世界声明的
        坐姿活动（`chair.sit` / `bunk.rest`）。只读诊断依据（渲染器 `worldSkeletonDiagnostics`
        + 世界坐标接地）：

          * **身体穿模**：脚面 / 全身最低接触点都不得低于静止脚面（地面参考）；
          * **座面支撑**：骨盆必须高于脚面（躯干被座面托住、腿垂在下面），且骨盆在采样窗口
            内高度稳定（不持续下沉 / 弹跳）；
          * **骨盆对齐**：骨盆水平位置留在坐姿入口（世界根位置）附近，不整个滑离座位。

        世界契约里没有可读的凳子网格，所以这里**不编造座面高度、不做任何位置补偿**；脚离地
        只作为诊断记录（凳子上双脚本来就可能悬空），绝不是缺陷。
        """
        clip = extract_motion_clip(status)
        active = status.get("activeActivity") or ""
        if not motion_is_explicit_sit(clip, active, self.sit_motion_id):
            self.ledger.blocked(
                f"{label}坐姿前提不成立，坐姿支撑未验证"
                f"（clip={clip or 'none'}，activeActivity={active or 'none'}，"
                f"显式坐姿 {self.sit_motion_id} / 坐姿活动 {list(SIT_ACTIVITY_IDS)}）",
                clip=clip, activeActivity=active, sitMotionID=self.sit_motion_id)
            return False
        avatar_format = str(status.get("avatarFormat") or "").lower()
        if avatar_format and avatar_format != "pmx":
            self.ledger.blocked(
                f"{label}当前人物不是 PMX，世界坐标坐姿诊断不可用",
                avatarFormat=status.get("avatarFormat"))
            return False
        fields = self.pose_world_fields(status)
        needed = ("lowestSoleWorldY", "lowestContactWorldY", "restFootPlaneWorldY",
                  "pelvisWorldX", "pelvisWorldY", "pelvisWorldZ")
        if not all(fields[key] is not None for key in needed):
            self.ledger.check(
                False, f"{label}坐姿世界坐标诊断可读（脚面/接触/骨盆）",
                worldGrounding=fields, avatarGrounding=status.get("avatarGrounding"))
            return False
        sole = float(fields["lowestSoleWorldY"])
        contact = float(fields["lowestContactWorldY"])
        plane = float(fields["restFootPlaneWorldY"])
        pelvis_x = float(fields["pelvisWorldX"])
        pelvis_y = float(fields["pelvisWorldY"])
        pelvis_z = float(fields["pelvisWorldZ"])
        sole_clearance = sole - plane
        contact_clearance = contact - plane
        self.ledger.info(
            f"{label}坐姿世界坐标诊断（脚离地在坐姿里允许，只作记录）",
            clip=clip, activeActivity=active, soleClearance=sole_clearance,
            contactClearance=contact_clearance, pelvisWorldY=pelvis_y,
            pelvisWorldX=pelvis_x, pelvisWorldZ=pelvis_z, worldGrounding=fields)
        # 身体穿模：地面参考是角色自己的静止脚面；坐姿脚可以离地，但绝不能穿地。
        self.ledger.check(
            min(sole_clearance, contact_clearance) >= -GROUNDING_TOLERANCE_M,
            f"{label}坐姿身体/脚都没有穿地（脚面 {sole_clearance:.4f} m / "
            f"接触 {contact_clearance:.4f} m，容差 -{GROUNDING_TOLERANCE_M}）",
            clip=clip, soleClearance=sole_clearance, contactClearance=contact_clearance)
        # 座面支撑：骨盆高于脚面（躯干被座位托住，不是整个人趴/穿进地面）。
        self.ledger.check(
            pelvis_y >= sole + SIT_PELVIS_ABOVE_FOOT_M,
            f"{label}坐姿骨盆高于脚面（骨盆 {pelvis_y:.4f} ≥ 脚面 {sole:.4f} + "
            f"{SIT_PELVIS_ABOVE_FOOT_M}）",
            pelvisWorldY=pelvis_y, soleWorldY=sole)
        # 骨盆对齐：水平位置留在坐姿入口（世界根位置）附近。
        position = status.get("residentPosition")
        if is_valid_position(position):
            offset = math.hypot(
                pelvis_x - float(position[0]), pelvis_z - float(position[2]))
            self.ledger.check(
                offset <= SIT_PELVIS_ALIGNMENT_TOLERANCE_M,
                f"{label}坐姿骨盆与坐姿入口水平对齐（偏移 {offset:.4f} m ≤ "
                f"{SIT_PELVIS_ALIGNMENT_TOLERANCE_M}）",
                pelvisWorldX=pelvis_x, pelvisWorldZ=pelvis_z,
                residentPosition=position)
        else:
            self.ledger.check(
                False, f"{label}坐姿入口（residentPosition）可读（三维有限值）",
                residentPosition=position)
        # 座面支撑的循环稳定性：逐帧骨盆高度不能持续下沉 / 弹跳。只取**确实是坐姿**的帧，
        # 避免站姿→坐姿的过渡帧把稳定性判红。
        if frames:
            sit_frames = [
                frame for frame in frames
                if motion_is_explicit_sit(
                    extract_motion_clip(frame),
                    frame.get("activeActivity"),
                    self.sit_motion_id)
            ]
            pelvis_samples = [
                extract_number(frame.get("avatarGrounding") or {}, "pelvisWorldY")
                for frame in sit_frames
            ]
            pelvis_samples = [value for value in pelvis_samples if value is not None]
            self.ledger.check(
                len(pelvis_samples) >= 2,
                f"{label}坐姿逐帧骨盆诊断可读（{len(pelvis_samples)}/{len(frames)}）",
                pelvisWorldY=pelvis_samples)
            if len(pelvis_samples) >= 2:
                span = max(pelvis_samples) - min(pelvis_samples)
                self.ledger.check(
                    span <= SIT_PELVIS_SPAN_TOLERANCE_M,
                    f"{label}坐姿骨盆在循环内稳定（跨度 {span:.4f} m ≤ "
                    f"{SIT_PELVIS_SPAN_TOLERANCE_M}）",
                    pelvisWorldY=pelvis_samples)
        return True

    def check_frame_no_penetration(self, label: str, frames: list[dict]) -> None:
        """逐帧世界坐标穿地判据（站姿 / 坐姿都成立，单边）。"""
        clearances = []
        for frame in frames:
            fg = frame.get("avatarGrounding") or {}
            f_sole = extract_number(fg, "lowestSoleWorldY")
            f_plane = extract_number(fg, "restFootPlaneWorldY")
            if f_sole is not None and f_plane is not None:
                clearances.append(f_sole - f_plane)
        if not clearances:
            self.ledger.check(False, f"{label}逐帧脚面诊断可读", frames=frames)
            return
        self.ledger.check(
            min(clearances) >= -GROUNDING_TOLERANCE_M,
            f"{label}逐帧脚面都不穿地（最低 {min(clearances):.4f} m）",
            frameSoleClearances=clearances)

    def verify_restart_foot_pose(self, status: dict) -> dict | None:
        """重启后姿态语义判定：**先判 clip 角色**，再套站姿或坐姿判据 + 真实 GPU 抓帧。

        用户 2026-10-03 更正：`activeActivity` 为空**不等于**站姿（默认动作可能就是坐在
        凳子上的坐姿）。这里只按渲染器真正装载的 clip 判：
          * 显式站姿 clip ⇒ 站姿贴地双边判据；
          * 坐姿 clip / 在跑坐姿活动 ⇒ 坐姿支撑 / 对齐 / 穿模判据（允许脚离地）；
          * 其它 ⇒ 具名 blocked，绝不默认站姿。
        并抓 6 帧真实 GPU 回读另存到 `<root>/evidence/restart-frames/` 供人工核验。
        """
        assert self.host is not None
        # 重启后显式回到站姿（生产入口，写测试根 selection）：坐姿/默认选择不得让"重启站姿
        # 贴地"这条判据空跑，也不许把坐姿当站姿。之后才按真正装载的 clip 判角色。
        self.activate_motion(self.stand_motion_id, timeout=min(self.args.timeout, 20))
        status = self.wait_standing_settled(
            "重启后", timeout=min(self.args.timeout, 30)) or status
        clip = extract_motion_clip(status)
        role = motion_role(clip, self.stand_motion_id, self.sit_motion_id)
        active = status.get("activeActivity") or ""
        self.ledger.info(
            "重启后动作角色判定（不以 activeActivity 为空假定站姿）",
            clip=clip, role=role, activeActivity=active,
            standMotionID=self.stand_motion_id, sitMotionID=self.sit_motion_id)
        frames = self.capture_grounded_frames(count=6, interval_ms=150)
        self.save_labeled_frames("restart", frames)
        if clip == self.stand_motion_id:
            self.check_standing_feet(status, "重启后显式站姿")
        elif motion_is_explicit_sit(clip, active, self.sit_motion_id):
            self.check_sit_support("重启后", status, frames)
            self.ledger.blocked(
                "重启后装载的是坐姿 clip，显式站姿贴地未验证"
                "（坐姿允许脚离地，已按坐姿支撑/对齐/穿模判据核验）",
                clip=clip, activeActivity=active)
        else:
            self.ledger.blocked(
                f"重启后既不是显式站姿 {self.stand_motion_id} 也不是坐姿，"
                "接地语义无法判定（不以空 activeActivity 假定站姿）",
                clip=clip, activeActivity=active, role=role)
        # 真实 GPU 重启抓帧：另存到命名目录，供主代理视觉核验"到底站在地上没有"。
        if not frames:
            self.ledger.check(False, "重启后抓到真实 GPU 帧供视觉核验", frames=frames)
            return status
        self.ledger.check(len(frames) >= 4,
                          f"重启后抓到至少 4 帧真实 GPU 回读（实际 {len(frames)}）", frames=frames)
        hashes = {f.get("sha256") for f in frames if f.get("sha256")}
        self.ledger.check(len(hashes) >= 2,
                          f"重启抓帧画面确实在变（{len(hashes)} 个摘要）",
                          hashes=sorted(h for h in hashes if h)[:8])
        self.check_frame_no_penetration("重启抓帧", frames)
        return status

    def activate_motion(self, motion_id: str, timeout: float) -> bool:
        """走**生产**动作入口显式选中站姿 / 坐姿动作，并等渲染器真的装载它。

        控制面 `activate_motion` 只在显式测试产物里存在，内部调用生产的
        `playCharacterMotion(id:)`（用户菜单同一条路径），写的是**测试根** selection。
        控制面回执不算成功：必须轮询 `status.avatarMotion.clip` 真的等于请求 ID。
        """
        assert self.host is not None
        response = self.host.command(
            "activate_motion", {"motionID": motion_id}, timeout=self.args.timeout)
        self.ledger.record("activate_motion", motionID=motion_id, response=response)
        if response.get("ok") is not True:
            self.ledger.blocked(
                f"测试根无法激活动作 {motion_id}（控制面报错）", response=response)
            return False
        deadline = time.monotonic() + timeout
        last_clip = ""
        while time.monotonic() < deadline:
            status_response = self.host.command("status")
            status = status_response.get("result", {}) if status_response.get("ok") else {}
            last_clip = extract_motion_clip(status)
            if last_clip == motion_id:
                return True
            time.sleep(0.25)
        self.ledger.blocked(
            f"激活动作 {motion_id} 后渲染器没有装载该 clip（最后 clip={last_clip or 'none'}）",
            motionID=motion_id, lastClip=last_clip)
        return False

    def verify_pose_stand(self, status: dict) -> None:
        """启动后的**显式站姿**判据（与坐姿分开）。

        先经生产入口显式选 `--stand-motion-id`（不被上一轮遗留选择左右），再核对 App 真的
        装载了它（复制包最后选中的 chair-sit 不得冒充站姿），最后判脚面贴地。clip 不符时
        具名 blocked，不猜站姿。
        """
        assert self.host is not None
        self.ledger.section("pose_stand")
        self.activate_motion(self.stand_motion_id, timeout=min(self.args.timeout, 20))
        status = self.wait_standing_settled(
            "启动后", timeout=min(self.args.timeout, 20)) or status
        self.check_standing_feet(status, "启动后显式站姿")

    def verify_pose_sit(self, status: dict) -> None:
        """启动后的**显式坐姿**判据（与站姿分开）。

        经生产入口把持久动作显式选成 `--sit-motion-id`（凳上坐姿），**允许脚离地**，判座面
        支撑 / 骨盆对齐 / 身体穿模。这就是用户指出的默认坐姿场景的直接覆盖（无活动时也可能
        显示坐姿，不能当站姿）。跑完切回显式站姿，后续段与基线不被坐姿状态带偏。
        """
        assert self.host is not None
        self.ledger.section("pose_sit")
        activated = self.activate_motion(
            self.sit_motion_id, timeout=min(self.args.timeout, 20))
        status = self.wait_status(
            lambda sample: extract_motion_clip(sample) == self.sit_motion_id,
            timeout=min(self.args.timeout, 20)) or status
        # 让站姿→坐姿的混合先走完，再抓"稳定坐姿"的帧供稳定性判据与人工核验。
        time.sleep(0.4)
        frames = self.capture_grounded_frames(count=6, interval_ms=150)
        self.save_labeled_frames("pose-sit", frames)
        if activated:
            self.check_sit_support("启动后显式坐姿", status, frames)
        else:
            self.ledger.blocked(
                "显式坐姿未激活，坐姿支撑/对齐/穿模未验证",
                sitMotionID=self.sit_motion_id)
        # 回到显式站姿：重启站姿判据与后续抓帧不被坐姿状态带偏。
        self.activate_motion(self.stand_motion_id, timeout=min(self.args.timeout, 20))

    def save_labeled_frames(self, label: str, frames: list[dict]) -> None:
        """把抓帧 PNG 另存到 `<root>/evidence/<label>-frames/`，文件名加标签防覆盖。

        同一轮里 `capture_frames` 会复用 `frames/frame-0000.png` 这套文件名；重启抓帧
        若不另存，会被后面的动作抓帧覆盖，主代理就没法回看"重启那一刻到底什么样"。
        """
        if not frames:
            return
        target = self.root / "evidence" / f"{label}-frames"
        target.mkdir(parents=True, exist_ok=True)
        for frame in frames:
            source_path = frame.get("path")
            if not source_path:
                continue
            source = Path(str(source_path))
            if not source.exists():
                continue
            destination = target / f"{label}-{int(frame.get('index', 0)):04d}.png"
            try:
                shutil.copy2(source, destination)
                frame["labeledPath"] = str(destination)
            except OSError:
                continue
        self.ledger.info(f"重启抓帧已另存供视觉核验（{label}）",
                         directory=str(target),
                         paths=[f.get("labeledPath") for f in frames if f.get("labeledPath")])

    # -- 非 HLS 声音对照 --------------------------------------------------------

    def verify_audio_reference(self, object_id: str) -> None:
        """在同一块真实屏幕上放**公开 file-based mp4**，做一次真实 PCM 链采样。

        与 HLS 那条分开：HLS 平台不支持 `audioMix`，`screen_audio` 仍 blocked、不改判。
        这条对照源是 `video/mp4`（`--audio-reference-url`，默认 W3C Sintel 预告片，带 AAC
        音轨），tap 能真的挂上并采到非静音 PCM；它证明"采样链本身可用"，不伪装成 HLS
        声音输出通过，也不引入任何系统录音/TCC 授权。
        """
        assert self.host is not None
        self.ledger.section("audio_reference")
        url = self.args.audio_reference_url
        self.ledger.info("非 HLS 公开 file-based mp4 音频对照源", url=url)
        # 生产 `play_screen` 的白名单只放受支持的公开观看页，直链会被具名拒绝；这条对照
        # 走宿主显式暴露的 `play_direct_media`（只在测试控制面存在），它交给**同一条**
        # 生产原生播放器 / 同一个 MTAudioProcessingTap。这里不伪装成 `play_screen` 通过。
        played = self.host.command(
            "play_direct_media", {"objectID": object_id, "url": url},
            timeout=self.args.timeout)
        self.ledger.record("play_direct_media", result=played)
        self.ledger.check(played.get("ok") is True, "对照源经生产原生播放器入口被接受",
                          result=played)
        if played.get("ok") is not True:
            self.ledger.blocked("对照源没有进入播放，真实链采样未执行", url=url, result=played)
            return
        screen = self.wait_screen_playing(object_id, timeout=self.args.timeout)
        self.ledger.check(screen is not None, "对照源真的在解码播放（不是命令成功）",
                          screen=screen)
        if screen is None:
            self.ledger.blocked("对照源没有解码出帧，真实链采样未执行", url=url)
            return
        native = screen.get("nativeLink") or {}
        self.ledger.check(native.get("isLive") is not True,
                          "对照源是点播文件而不是 HLS 直播清单", nativeLink=native)
        self.check_screen_audio(object_id, label="非 HLS 对照", section=False)

    def verify_chat_turn(self) -> None:
        """走**生产** `submit_wish` 提交门，验证真实 chat 回合链路。

        与生成步骤的 `tool_call submit_wish_generation` 不同：这里经
        `sendResidentSubmission`（界面发送键的同一条路）登记可见回合并进入
        `AgentConversationService.send`。三项分开判：
          1. 回合真的被登记（`chatTurns` 里有同一个 submissionID + 原文）；
          2. 真的进了对话服务（`agentConversation.sendEnteredCount` 增长）；
          3. 循环真的起了模型轮次（`residentLoop.modelTurnsStarted` 增长）。
        终态只认事实：`delivered` 通过；`failed`/`cancelled`/`interrupted` 具名
        记为 blocked（环境/后端问题不算通过），并把 `lastFailure`/中断原因写进账本。
        没有可用后端时直接 blocked，绝不空跑通过。
        """
        assert self.host is not None
        self.ledger.section("chat_turn")
        status = self.host.command("status").get("result", {})
        conversation = status.get("agentConversation") or {}
        if conversation.get("hasUsableConversationBackend") is not True:
            self.ledger.blocked("没有可用的真实对话后端，真实 chat 回合无法验证",
                                agentConversation=conversation)
            return
        baseline_sends = int(conversation.get("sendEnteredCount") or 0)
        loop_before = status.get("residentLoop") or {}
        baseline_turns = int(loop_before.get("modelTurnsStarted") or 0)
        sentinel = "E2E 对话回合 " + uuid.uuid4().hex[:8]
        response = self.host.command("submit_wish", {"text": sentinel},
                                     timeout=self.args.timeout)
        self.ledger.check(response.get("ok") is True,
                          "真实用户输入经生产提交门被接受", result=response)
        submission_id = (response.get("result") or {}).get("submissionID")
        self.ledger.check(bool(submission_id), "提交门回执带回合编号",
                          submissionID=submission_id)
        if not submission_id:
            return
        deadline = time.monotonic() + self.args.chat_timeout
        last: dict = {}
        final_turn: dict | None = None
        while time.monotonic() < deadline:
            last = self.host.command("status").get("result", {})
            turns = last.get("chatTurns") or []
            loop = last.get("residentLoop") or {}
            convo = last.get("agentConversation") or {}
            final_turn = next(
                (turn for turn in turns if turn.get("id") == submission_id), None)
            if (final_turn
                    and int(convo.get("sendEnteredCount") or 0) > baseline_sends
                    and int(loop.get("modelTurnsStarted") or 0) > baseline_turns
                    and final_turn.get("delivery") != "sending"):
                break
            time.sleep(1.0)
        turns = last.get("chatTurns") or []
        loop = last.get("residentLoop") or {}
        convo = last.get("agentConversation") or {}
        registered = next((turn for turn in turns if turn.get("id") == submission_id), None)
        self.ledger.check(
            registered is not None and registered.get("userText") == sentinel,
            "生产提交门把这一轮登记进可见历史（回合编号 + 原文）",
            turn=registered, chatScopeKey=last.get("chatScopeKey"))
        self.ledger.check(
            int(convo.get("sendEnteredCount") or 0) > baseline_sends,
            "这一轮真的进入了对话服务（sendEnteredCount 增长）",
            before=baseline_sends, after=convo.get("sendEnteredCount"),
            lastSend=convo.get("lastSend"))
        self.ledger.check(
            int(loop.get("modelTurnsStarted") or 0) > baseline_turns,
            "这一轮真的起了模型轮次（modelTurnsStarted 增长）",
            before=baseline_turns, after=loop.get("modelTurnsStarted"))
        delivery = (final_turn or {}).get("delivery")
        if delivery == "delivered":
            self.ledger.check(True, "真实 chat 回合收到终态：已送达",
                              turn=final_turn)
            if not ((final_turn or {}).get("replyText") or "").strip():
                self.ledger.info("这一轮是静默完成（没有回复文本，但仍算已送达）",
                                 turn=final_turn)
        elif delivery in ("failed", "cancelled", "interrupted"):
            failure = self.resident_failure_for_turn(convo, final_turn)
            detail = "/".join(
                str(failure.get(key) or "") for key in ("stage", "code", "category", "detail")
            ).strip("/")
            self.ledger.blocked(
                f"真实 chat 回合终态为 {delivery}（不是通过；内部失败因 {detail or '未知'}）",
                turn=final_turn, lastFailure=loop.get("lastFailure"),
                residentFailure=failure,
                residentFailures=convo.get("recentResidentFailures"))
        else:
            self.ledger.check(False, "真实 chat 回合在期限内到达终态（不是一直 sending）",
                              turn=final_turn, lastFailure=loop.get("lastFailure"))

    def restart(self) -> None:
        assert self.host is not None
        self.host.quit()
        self.host = AppHost(self.app, self.root)
        self.host.launch(timeout=self.args.timeout)
        self.ledger.info("测试 App 已用同一数据根重启", root=str(self.root))

    def wait_status(self, predicate, timeout: float) -> dict:
        assert self.host is not None
        deadline = time.monotonic() + timeout
        last: dict = {}
        while time.monotonic() < deadline:
            response = self.host.command("status")
            last = response.get("result", {}) if response.get("ok") else {}
            if predicate(last):
                return last
            time.sleep(1.0)
        return last

    def wait_grounding_consistent(self, label: str, timeout: float) -> dict:
        """轮询到"补偿后接触点不低于静止参考"成立的那一帧 status 再断言。

        刚重启 / 刚换动作时，渲染器的补偿可能晚一帧才施加（`clearMotion` 会把偏移清零，
        要等下一次真实渲染重新算出）。这里按真实渲染帧等它收敛，超时返回最后一次读数，
        由 `check_avatar_grounding` 如实判红 —— 不用"读一次可能踩到空窗"的假失败，也不
        把持续不收敛的缺陷放过去。返回的 status 里带 `groundingWaitSeconds` 供账本诊断。
        """
        assert self.host is not None
        deadline = time.monotonic() + timeout
        started = time.monotonic()
        last: dict = {}
        while time.monotonic() < deadline:
            response = self.host.command("status")
            status = response.get("result", {}) if response.get("ok") else {}
            last = status
            grounding = status.get("avatarGrounding")
            if isinstance(grounding, dict):
                minimum = grounding.get("minimumContactY")
                rest = grounding.get("restGlobalReferenceY")
                applied = grounding.get("appliedGroundingOffsetY")
                if not isinstance(applied, (int, float)):
                    applied = grounding.get("groundingOffsetY")
                if (isinstance(minimum, (int, float)) and isinstance(rest, (int, float))
                        and isinstance(applied, (int, float))
                        and float(minimum) + float(applied) + GROUNDING_TOLERANCE_M
                        >= float(rest)):
                    last = dict(status)
                    last["groundingWaitSeconds"] = time.monotonic() - started
                    return last
            time.sleep(0.25)
        last = dict(last)
        last["groundingWaitSeconds"] = time.monotonic() - started
        return last

    def check_avatar_grounding(self, status: dict, label: str) -> None:
        """角色空间位置与地面接触的端到端判据。

        依赖宿主在 `status` 里暴露的 `residentPosition` 与 `avatarGrounding`
        （最小接触顶点局部 Y、接地偏移、根偏移）。缺字段 = 入口没暴露 ⇒ FAIL，
        不是跳过。判据本身只读事实：位置有限、脚底/最低接触点不低于地面。
        """
        position = status.get("residentPosition")
        if not (isinstance(position, list) and len(position) == 3
                and all(isinstance(v, (int, float)) for v in position)):
            self.ledger.check(False, f"{label}居民空间位置可读（三维有限值）",
                              residentPosition=position)
            return
        self.ledger.check(all(abs(float(v)) < 1e6 for v in position),
                          f"{label}居民空间位置是有限值", residentPosition=position)
        grounding = status.get("avatarGrounding")
        if not isinstance(grounding, dict):
            self.ledger.check(False, f"{label}宿主暴露了 avatarGrounding（地面接触入口）",
                              avatarGrounding=grounding)
            return
        minimum_y = grounding.get("minimumContactY")
        rest_y = grounding.get("restGlobalReferenceY")
        offset = grounding.get("appliedGroundingOffsetY")
        if not isinstance(offset, (int, float)):
            offset = grounding.get("groundingOffsetY")
        lift = grounding.get("contactLiftY")
        uncompensated = grounding.get("uncompensatedPenetrationY")
        self.ledger.check(
            isinstance(minimum_y, (int, float)),
            f"{label}最低接触顶点可读（minimumContactY={minimum_y}）",
            avatarGrounding=grounding)
        self.ledger.check(
            isinstance(offset, (int, float)) and abs(float(offset)) < 100,
            f"{label}接地偏移是有限值（groundingOffsetY={offset}）",
            avatarGrounding=grounding)
        if isinstance(lift, (int, float)) and isinstance(uncompensated, (int, float)):
            self.ledger.check(
                float(lift) + 0.05 >= float(uncompensated),
                f"{label}全身接触补偿覆盖穿透（lift={lift} ≥ 未补偿={uncompensated}）",
                avatarGrounding=grounding)
            self.ledger.check(
                float(lift) >= -0.0001,
                f"{label}接触补偿只抬升不下压（lift={lift}）",
                avatarGrounding=grounding)
        else:
            self.ledger.check(False, f"{label}宿主暴露了接触补偿字段", avatarGrounding=grounding)
        # 补偿后接触点不得低于静止参考：把"offset 算出来但没施加 / 被清零"钉红。
        if (isinstance(minimum_y, (int, float)) and isinstance(rest_y, (int, float))
                and isinstance(offset, (int, float))):
            self.ledger.check(
                float(minimum_y) + float(offset) + GROUNDING_TOLERANCE_M >= float(rest_y),
                f"{label}补偿后接触点不低于静止参考"
                f"（min+offset={float(minimum_y) + float(offset):.4f} ≥ rest={rest_y}）",
                avatarGrounding=grounding)
        else:
            self.ledger.check(False, f"{label}宿主暴露了静止参考（restGlobalReferenceY）",
                              avatarGrounding=grounding)

    # -- 真实活动入口 + 连续运动帧接地 ------------------------------------------

    def run_activity_motion(self) -> None:
        """真的触发行走 / 跳跃 / 坐下，并在**运动中**逐帧验接地。

        上一版驱动器只做 idle 接地，静止状态永远"接通地面"，等于没验穿地。这里：
          1. 用生产 `list_available_activities` 发现当前世界声明了哪些活动；
          2. 对 walk / jump / sit 三类各选一个候选，经生产 `start_activity` 启动；
          3. 等 `status.activeActivity` 真的是它（不是命令成功），再连续抓帧并逐帧验接地；
          4. 生产 `stop_activity` 收尾。
        世界没声明的类别不冒充通过：仍然调一次生产入口拿到具名拒绝码后如实记录。
        """
        assert self.host is not None
        self.ledger.section("activity_motion")
        listing = self.tool("list_available_activities", {})
        activities = extract_available_activities(listing)
        available = {a["id"] for a in activities if isinstance(a.get("id"), str)}
        self.ledger.check(
            listing.get("ok") is True and bool(activities),
            f"世界声明的可执行活动可读（{len(activities)} 项）",
            activities=activities,
        )
        exercised = 0
        for label, category, candidates in ACTIVITY_CANDIDATES:
            chosen = choose_activity(candidates, available)
            if chosen is None:
                # 世界没声明：仍然触发一次生产入口，拿到具名拒绝（证明入口控制真的在
                # 工作），但**不**记 pass —— 这是"本世界无法验证该类别"，不是通过。
                denial = self.tool("start_activity", {"activity_id": candidates[0]})
                self.ledger.info(
                    f"{label}：当前世界未声明该活动，入口按名拒绝；本类别未验证",
                    worldID=None, requested=candidates[0],
                    code=extract_world_tool_code(denial),
                    availableActivities=sorted(available),
                )
                continue
            if not self.exercise_activity(label, category, chosen):
                continue
            exercised += 1
        self.ledger.check(
            exercised > 0,
            "至少触发并验证了一项真实非待机活动（不能只用 idle 接地冒充穿地已验）",
            exercised=exercised,
        )

    def exercise_activity(self, label: str, category: str, activity_id: str) -> bool:
        assert self.host is not None
        started = self.tool("start_activity", {"activity_id": activity_id})
        ok = world_tool_succeeded(started)
        self.ledger.check(ok, f"{label}活动入口接受了 start_activity（{activity_id}）",
                          result=started)
        if not ok:
            return False
        self._current_activity = activity_id
        active = self.wait_active_activity(activity_id, timeout=min(self.args.timeout, 30))
        self.ledger.check(active is not None,
                          f"{label}活动真的进入运行态（不是命令成功）",
                          activityID=activity_id, status=active)
        if active is None:
            self.tool("stop_activity", {})
            self._current_activity = None
            return False
        # 让片段先走一小段：抓的是"运动过程中"，不是第一帧的静止 pose。窗口取短一点
        # （6 帧 × 80 ms），有限表演自然结束时也还能留住 ≥3 帧真实运动。
        time.sleep(0.4)
        frames = self.capture_grounded_frames(count=6, interval_ms=80)
        self.check_motion_track(label, category, activity_id, frames)
        stopped = self.tool("stop_activity", {"reason": f"E2E {label}验证完成"})
        self.ledger.check(world_tool_succeeded(stopped),
                          f"{label}活动已按 stop_activity 停止", result=stopped)
        self._current_activity = None
        return bool(frames)

    def wait_active_activity(self, activity_id: str, timeout: float) -> dict | None:
        assert self.host is not None
        deadline = time.monotonic() + timeout
        last: dict = {}
        while time.monotonic() < deadline:
            response = self.host.command("status")
            last = response.get("result", {}) if response.get("ok") else {}
            if last.get("activeActivity") == activity_id:
                return last
            time.sleep(0.5)
        return None

    def capture_grounded_frames(self, count: int, interval_ms: int) -> list[dict]:
        assert self.host is not None
        response = self.host.command(
            "capture_frames",
            {"count": count, "intervalMs": interval_ms, "trackGrounding": True},
            timeout=self.args.timeout,
        )
        if response.get("ok") is not True:
            self.ledger.check(False, "带接地采样的连续运动帧可抓取", result=response)
            return []
        frames = response.get("result", {}).get("frames", [])
        return frames if isinstance(frames, list) else []

    def check_motion_track(
        self, label: str, category: str, activity_id: str, frames: list[dict]
    ) -> None:
        """连续运动帧判据：画面在变、动画帧在推进、活动持续、逐帧未穿地。"""
        if not frames:
            self.ledger.check(False, f"{label}抓到了连续运动帧", frames=frames)
            return
        self.ledger.check(len(frames) >= 4,
                          f"{label}抓到至少 4 帧连续运动（实际 {len(frames)}）", frames=frames)
        hashes = {f.get("sha256") for f in frames if f.get("sha256")}
        self.ledger.check(len(hashes) >= 2,
                          f"{label}运动帧画面确实在变（{len(hashes)} 个摘要）",
                          hashes=sorted(h for h in hashes if h)[:8])
        revisions = [f.get("avatarFrameRevision") for f in frames
                     if isinstance(f.get("avatarFrameRevision"), int)]
        # 资源 revision（旧判据）只作为**诊断信息**入账：它回答"选中了哪份资源"，
        # 回答不了"骨头在动吗"。验收改用下面的逐帧结构化骨骼姿态 + 播放时钟。
        self.ledger.info(
            f"{label}资源 revision（仅诊断，不再作为动作判据）",
            revisions=revisions,
        )
        self.check_motion_pose(label, activity_id, frames)
        activities = [f.get("activeActivity") for f in frames]
        motion_frames = [a for a in activities if a == activity_id]
        # 有限表演（如开合跳）可能在采样窗口里自然结束，所以要求的是"至少 3 帧真的
        # 处在该活动里"，而不是整段都命中断言；活动序列如实入账，便于具名诊断。
        self.ledger.check(
            len(motion_frames) >= 3,
            f"{label}采样窗口里至少有 3 帧真的在跑该活动（{len(motion_frames)}/{len(frames)}）",
            activities=activities,
        )
        grounded = sum(
            1 for frame in frames
            if motion_grounding_ok(frame.get("avatarGrounding"), frame.get("residentPosition"))
        )
        self.ledger.record(
            "motion_grounding", activityID=activity_id, category=category,
            grounded=grounded, total=len(frames),
        )
        self.ledger.check(
            grounded == len(frames),
            f"{label}每一帧运动中都未穿地（补偿后接触点不低于静止参考，{grounded}/{len(frames)}）",
            frames=[{
                "index": f.get("index"),
                "avatarGrounding": f.get("avatarGrounding"),
                "residentPosition": f.get("residentPosition"),
            } for f in frames],
        )
        positions = [f.get("residentPosition") for f in frames]
        span = position_span(positions)
        if category == "walk":
            self.ledger.check(
                span >= 0.01,
                f"{label}行走真的产生了位移（跨度 {span:.4f} m，静止不算走）",
                span=span,
            )
        else:
            self.ledger.info(f"{label}采样窗口内位移跨度 {span:.4f} m")
        if category == "sit":
            # 坐姿**不按站姿脚贴地**判：坐姿脚本来就可能离地。这里显式判座面支撑 / 骨盆
            # 对齐 / 身体穿模。取一帧真的在跑该活动的样本作为 status 投影（帧里带接地 +
            # 骨盆诊断），逐帧稳定性直接用整段 frames。
            sample = next(
                (frame for frame in frames
                 if frame.get("activeActivity") == activity_id),
                frames[0],
            )
            self.check_sit_support(
                label,
                {
                    "avatarGrounding": sample.get("avatarGrounding"),
                    "avatarMotion": sample.get("avatarMotion"),
                    "residentPosition": sample.get("residentPosition"),
                    "activeActivity": sample.get("activeActivity"),
                },
                frames,
            )

    def scene_clock_segments(
        self, samples: list[tuple[dict, dict]]
    ) -> list[dict]:
        """把逐帧采样按 `(clip, motionInstallEpoch)` 切成**连续段**。

        安装/清除 motion 会把本地动画时钟归零；这是真实发生的片段切换，不是时钟
        倒退。没有 `motionInstallEpoch`（旧产物）时就地推断：clip 变了或 sceneTime
        变小都开新段。段内 clock 必须非递减，段间归零允许但必须能指认出身份变化。
        """
        segments: list[dict] = []
        inferred_epoch = 0
        previous_clip: str | None = None
        previous_time: float | None = None
        for frame, motion in samples:
            clip = str(motion.get("clip") or "")
            raw_epoch = motion.get("motionInstallEpoch")
            if isinstance(raw_epoch, int):
                key = (clip, raw_epoch)
            else:
                if previous_clip is not None and (
                    clip != previous_clip
                    or (previous_time is not None
                        and self._number(motion.get("sceneTime")) is not None
                        and self._number(motion.get("sceneTime")) < previous_time)
                ):
                    inferred_epoch += 1
                key = (clip, "inferred:{}".format(inferred_epoch))
            if segments and segments[-1]["key"] == key:
                segments[-1]["samples"].append((frame, motion))
            else:
                segments.append({"key": key, "samples": [(frame, motion)]})
            previous_clip = clip
            previous_time = self._number(motion.get("sceneTime"))
        return segments

    @staticmethod
    def _number(value) -> float | None:
        return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None

    def check_motion_pose(self, label: str, activity_id: str, frames: list[dict]) -> None:
        """真实姿态判据：真实播放器 + 播放时钟推进 + 骨骼姿态真的在变。

        这是取代旧 `avatarFrameRevision`（资源 revision）的验收指标。资源 revision 只
        回答"选中了哪份资源"；GPU `frameIndex` 只回答"抓了第几张图"。两者都可能不变或
        照常递增而骨头一动不动。这里读的是 `PMXStageAvatarRenderer` 的**真实**播放事实：
        `clip` / `hasPlayer` / `sceneTime`（渲染时钟）/ `motionInstallEpoch`（播放 epoch）/
        `renderedAvatarFrameCount`（只随真实角色帧递增）/ 每根骨骼相对静止姿态的角度。
        """
        samples = [
            (frame, frame.get("avatarMotion"))
            for frame in frames
            if isinstance(frame.get("avatarMotion"), dict) and frame.get("avatarMotion")
        ]
        motions = [motion for _, motion in samples]
        self.ledger.check(
            len(motions) >= 4,
            f"{label}逐帧结构化动作诊断可读（avatarMotion，{len(motions)}/{len(frames)}）",
            avatarMotion=motions,
        )
        if len(motions) < 4:
            return
        clips = [str(m.get("clip") or "") for m in motions]
        players = [m.get("hasPlayer") is True for m in motions]
        player_frames = sum(1 for p in players if p)
        self.ledger.check(
            player_frames >= 3,
            f"{label}逐帧都有真实动画播放器（hasPlayer，{player_frames}/{len(motions)}）",
            clips=clips, hasPlayers=players,
        )
        self.ledger.check(
            all(clip not in ("", "none") for clip in clips),
            f"{label}逐帧都读到了已装载的 clip（不是 none）", clips=clips,
        )
        # 时钟判据按 (clip, 播放 epoch) 分段：同一段内 sceneTime 必须推进；跨段归零是
        # clip/播放器切换，不算倒退，但**必须**有至少一段真的在推进，且倒退只允许发生在
        # 段首。整段每帧都重置（每段只有一个采样）会红，冻结时钟也会红。
        segments = self.scene_clock_segments(samples)
        segment_report = []
        backward_within_segment = False
        progressing_segments = 0
        activity_segments = 0
        for segment in segments:
            times = [self._number(m.get("sceneTime")) for _, m in segment["samples"]]
            times = [t for t in times if t is not None]
            activities = [f.get("activeActivity") for f, _ in segment["samples"]]
            on_activity = any(a == activity_id for a in activities)
            monotone = all(b >= a for a, b in zip(times, times[1:]))
            advanced = len(times) >= 2 and times[-1] > times[0]
            if not monotone:
                backward_within_segment = True
            if advanced:
                progressing_segments += 1
                if on_activity:
                    activity_segments += 1
            segment_report.append({
                "clip": segment["key"][0],
                "epoch": segment["key"][1],
                "count": len(times),
                "span": (times[-1] - times[0]) if len(times) >= 2 else 0.0,
                "onActivity": on_activity,
                "monotone": monotone,
            })
        self.ledger.info(
            f"{label}播放时钟分段（按 clip+epoch）", segments=segment_report,
        )
        self.ledger.check(
            not backward_within_segment,
            f"{label}同一 clip/播放 epoch 段内时钟没有倒退",
            segments=segment_report,
        )
        self.ledger.check(
            progressing_segments >= 1,
            f"{label}至少有一段 clip/epoch 内播放时钟真实推进"
            f"（可用推进段 {progressing_segments}/{len(segments)}）",
            segments=segment_report,
        )
        self.ledger.check(
            activity_segments >= 1,
            f"{label}目标活动运行期间有可推进的播放时钟段"
            f"（{activity_segments} 段命中活动 {activity_id}）",
            segments=segment_report,
        )
        scene_times = [m.get("sceneTime") for m in motions
                       if isinstance(m.get("sceneTime"), (int, float))]
        self.ledger.info(
            f"{label}原始 sceneTime 序列（跨段归零只作诊断）", sceneTimes=scene_times,
        )
        rendered = [m.get("renderedAvatarFrameCount") for m in motions
                    if isinstance(m.get("renderedAvatarFrameCount"), int)]
        self.ledger.check(
            len(rendered) >= 4 and all(b > a for a, b in zip(rendered, rendered[1:])),
            f"{label}采样落在真实角色渲染帧上（renderedAvatarFrameCount 递增）",
            renderedAvatarFrameCounts=rendered,
        )
        rest_counts = [m.get("restBoneCount") for m in motions
                       if isinstance(m.get("restBoneCount"), int)]
        rest_bones = max(rest_counts) if rest_counts else 0
        self.ledger.check(
            rest_bones >= 2,
            f"{label}诊断骨骼已映射到骨架（restBoneCount={rest_bones}，至少 2 根）",
            restBoneCounts=rest_counts,
        )
        digests = [m.get("poseDigest") for m in motions
                   if isinstance(m.get("poseDigest"), (int, float))]
        max_angles = [m.get("maximumBoneAngleDegrees") for m in motions
                      if isinstance(m.get("maximumBoneAngleDegrees"), (int, float))]
        if len(digests) >= 4 and len(max_angles) >= 4:
            digest_sweep = max(digests) - min(digests)
            bone_sweep = max(max_angles) - min(max_angles)
            self.ledger.check(
                max(max_angles) > 1.0 and (digest_sweep > 1.0 or bone_sweep > 1.0),
                f"{label}骨骼姿态真的在变（最大骨骼角 {max(max_angles):.2f}°，"
                f"姿态 digest 跨度 {digest_sweep:.2f}°，单骨跨度 {bone_sweep:.2f}°）",
                maximumBoneAngles=max_angles, poseDigests=digests,
            )
        else:
            self.ledger.check(False, f"{label}逐帧骨骼姿态角度可读", motions=motions)

    def wait_screen_playing(self, object_id: str, timeout: float) -> dict | None:
        """轮询 `playback_state`，返回这一块屏**真的在放**时的行；超时返回 None。

        判据不是"命令成功"，是 `surface == playing` **且** `nativeLink.decodedFrames > 0`。
        """
        assert self.host is not None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.host.command("playback_state")
            result = response.get("result", {}) if response.get("ok") else {}
            for screen in result.get("screens", []):
                if screen.get("objectID") != object_id:
                    continue
                native = screen.get("nativeLink") or {}
                if screen.get("surface") == "playing" and int(native.get("decodedFrames") or 0) >= 2:
                    return screen
            time.sleep(1.0)
        return None

    def check_screen_audio(self, object_id: str, label: str = "电视",
                           section: bool = True) -> None:
        """屏幕**声音链**的端到端判据：真实 PCM 采样，不是"命令成功"。

        读 `playback_state` 里这块屏的 `nativeLink`：`isMuted` / `volume` / `rate` 是
        AVPlayer 的直接读数；`sampledAudioBuffers` / `sampledAudioFrames` /
        `audioPeakAmplitude` 来自 `MTAudioProcessingTap` 在输出前取到的**解码 PCM**。
        没有采样缓冲 = 没有声音证据；tap 挂不上（平台/轨道协商）如实 blocked，不冒充通过。

        `label` 只改日志主语：HLS 那条仍是"电视"且不改判；非 HLS 对照用"非 HLS 对照"。
        """
        assert self.host is not None
        if section:
            self.ledger.section("screen_audio")
        deadline = time.monotonic() + min(self.args.timeout, 30)
        last: dict = {}
        while time.monotonic() < deadline:
            response = self.host.command("playback_state")
            result = response.get("result", {}) if response.get("ok") else {}
            for screen in result.get("screens", []):
                if screen.get("objectID") == object_id:
                    last = screen.get("nativeLink") or {}
            if (int(last.get("sampledAudioBuffers") or 0) > 0
                    and float(last.get("audioPeakAmplitude") or 0) > 0):
                break
            time.sleep(0.5)
        self.ledger.check(bool(last), f"{label}声音诊断可读（nativeLink）", nativeLink=last)
        if not last:
            return
        self.ledger.check(last.get("isMuted") is False, f"{label}播放器没有静音", nativeLink=last)
        self.ledger.check(float(last.get("volume") or 0) > 0, f"{label}播放器音量大于 0",
                          nativeLink=last)
        self.ledger.check(float(last.get("rate") or 0) > 0, f"{label}播放器在真实播放速率",
                          nativeLink=last)
        if last.get("audioTapAttached") is not True:
            sampler = getattr(self.args, "audio_output_sampler", None)
            if sampler and last.get("audioTapInstallDetail") == "unsupported:hls-manifest":
                assert self.host.process is not None
                pid = self.host.process.pid
                evidence = self.root / "evidence" / f"hls-output-{uuid.uuid4().hex}.json"
                try:
                    def sample(expect, path):
                        run = subprocess.run(
                            [sampler, "--pid", str(pid), "--seconds", "8",
                             "--expect", expect, "--output", str(path)],
                            capture_output=True, text=True, timeout=60, check=False)
                        data = json.loads(path.read_text()) if path.exists() else {}
                        scoped = (data.get("targetPid") == pid
                                  and data.get("scopedProcesses") == [pid]
                                  and data.get("globalTap") is False)
                        return run.returncode == 0 and scoped, data
                    playing_ok, playing = sample("audible", evidence)
                    stopped = self.tool("stop_screen", {"object_id": object_id})
                    time.sleep(1)
                    quiet_ok, quiet = sample("silent", evidence.with_suffix(".quiet.json"))
                    report = {"playing": playing, "quiet": quiet}
                    passed = (playing_ok and quiet_ok and stopped.get("ok") is True
                              and int(playing.get("tapBuffers") or 0) > 0
                              and int(quiet.get("tapBuffers") or 0) > 0
                              and float(playing.get("rms") or 0) >= 0.0005
                              and float(playing.get("rms") or 0)
                              >= 4 * max(float(quiet.get("rms") or 0), 0.000001))
                    self.ledger.check(passed, f"{label}指定测试进程 HLS 输出开停对照",
                                      report=report)
                except (subprocess.TimeoutExpired, OSError, ValueError) as error:
                    self.ledger.check(False, f"{label}系统输出采样未完成", error=str(error))
                finally:
                    restored = self.tool("play_screen", {"object_id": object_id,
                                                          "url": self.args.video_url})
                    self.ledger.check(restored.get("ok") is True,
                                      "声音开停对照后恢复正式电视播放")
                    self.wait_screen_playing(object_id, timeout=self.args.timeout)
                return
            self.ledger.blocked(f"{label}音频采样 tap 没有挂上（平台/轨道协商），真实声音采样缺失",
                                nativeLink=last)
            return
        buffers = int(last.get("sampledAudioBuffers") or 0)
        frames = int(last.get("sampledAudioFrames") or 0)
        peak = float(last.get("audioPeakAmplitude") or 0)
        if buffers == 0 and last.get("hasAudio") is False:
            self.ledger.blocked(f"{label}资源声明没有音频轨，无法验证声音", nativeLink=last)
            return
        self.ledger.check(buffers > 0, f"{label}真实音频采样缓冲在增长（buffers={buffers}）",
                          nativeLink=last)
        self.ledger.check(frames > 0, f"{label}真实音频采样帧在增长（frames={frames}）",
                          nativeLink=last)
        self.ledger.check(peak > 0, f"{label}采样到非静音峰值（peak={peak:.4f}）", nativeLink=last)
        self.ledger.info(f"{label}声音证据：真实解码 PCM 采样（tap 直通，不静音不改音量）",
                         nativeLink=last)

    def wait_screen_render(self, timeout: float) -> dict | None:
        """轮询 `playback_state.screenVideo`，等到渲染器真的画了电视画面。

        判据不是命令成功、也不是扫描/解码统计，而是：
        `drawPasses > 0`（渲染器消费了取帧注册表并编码了视频纹理）**且**
        `fragments > 0`（GPU 可见性查询证明四边形通过了深度测试、有像素写进 drawable）。
        超时返回最后一次读数（驱动器的 assert 会把它写进账本，便于具名诊断）。
        """
        assert self.host is not None
        deadline = time.monotonic() + timeout
        last: dict = {}
        while time.monotonic() < deadline:
            response = self.host.command("playback_state")
            result = response.get("result", {}) if response.get("ok") else {}
            last = result.get("screenVideo") or {}
            if (int(last.get("drawPasses") or 0) > 0
                    and int(last.get("fragments") or 0) > 0):
                return last
            time.sleep(0.5)
        return last or None

    def authorize_wish(self) -> dict | None:
        assert self.host is not None
        image = Path(self.args.asset_image).expanduser()
        if not image.is_file():
            self.ledger.blocked("只读素材不存在，无法打开生成授权", image=str(image))
            return None
        response = self.host.command("wish_authorize", {"attachments": [str(image)]})
        self.ledger.record("wish_authorize", response=response)
        if not response.get("ok"):
            self.ledger.blocked("生成授权失败", error=response.get("error"))
            return None
        return response.get("result")

    def submit_wish(self, authorization: dict | None) -> dict | None:
        assert self.host is not None
        if not authorization:
            return None
        attachment_id = (authorization.get("attachmentIDs") or [None])[0]
        response = self.host.command("tool_call", {
            "name": "submit_wish_generation",
            "arguments": {
                "attachment_id": attachment_id,
                "name": self.args.prop_name,
                "size_intent": {
                    "mode": "dimensions",
                    "millimeters": {"x": 400, "y": 250, "z": 60},
                    "source": "user",
                },
            },
        }, timeout=self.args.timeout)
        self.ledger.record("submit_wish_generation", response=response)
        result = response.get("result", {}) if response.get("ok") else {}
        inner = result.get("result", {})
        if not response.get("ok") or result.get("isError"):
            self.ledger.blocked("真实生成提交未成功；按回执具名诊断",
                                code=inner.get("code"), providerMessage=inner.get("message"))
            return None
        job_id = inner.get("wish_id")
        if not job_id:
            self.ledger.blocked("生成提交回执没有任务编号", response=response)
            return None
        # **等真实下载检查完成**（stage=ready 且有本地模型文件）。上一轮把
        # `generated`（服务已生成、尚未下载检查）当就绪，紧接着的 claim 必然拿到
        # `notReady`；这里只认 `ready`/`claimed`。
        job = self.wait_wish_ready(job_id, timeout=self.args.generation_timeout)
        if job is None:
            self.ledger.blocked(
                "生成任务在期限内没有完成下载检查（不把 generated 当就绪）", jobID=job_id)
            return None
        return job

    def resolve_existing_wish(self, wish_id: str) -> dict | None:
        """`--existing-wish-id`：不生成，只接着验这个**已存在**的任务。

        这是显式的恢复测试模式，用来复用上一轮已经真实生成好的产物（避免重复花费）。
        它只轮询同一个测试根/作用域里读回来的那条任务，等到真实下载检查完成；
        读不到就是具名 blocked，**绝不新建任务、绝不再消耗一次生成授权**。
        """
        assert self.host is not None
        job = self.wait_wish_ready(wish_id, timeout=self.args.generation_timeout)
        if job is None:
            self.ledger.blocked(
                "已有许愿任务在本测试根里没有完成下载检查（恢复模式不重新生成）",
                wishID=wish_id)
            return None
        self.ledger.info("复用已有许愿任务（未重新生成、未消耗新授权）", job=job)
        return job

    @staticmethod
    def resident_failure_for_turn(conversation: dict, turn: dict | None) -> dict:
        """从只读诊断里挑出与这一轮失败最匹配的内部失败因。

        优先 `lastResidentFailure`；它会被更晚的成功/失败覆盖，所以再用有界历史
        `recentResidentFailures` 按时间挑 `at` 不早于回合创建时间的第一条。只读，
        不改变任何行为；没有任何记录时返回 {}。
        """
        if not isinstance(conversation, dict):
            return {}
        last = conversation.get("lastResidentFailure")
        if isinstance(last, dict) and last:
            return last
        history = conversation.get("recentResidentFailures")
        if not isinstance(history, list):
            return {}
        records = [row for row in history if isinstance(row, dict) and row]
        if not records:
            return {}
        created = turn.get("createdAt") if isinstance(turn, dict) else None
        if not isinstance(created, (int, float)):
            return records[-1]
        for row in records:
            at = row.get("at")
            if isinstance(at, (int, float)) and float(at) >= float(created):
                return row
        return records[-1]

    @staticmethod
    def wish_download_checked(job: dict) -> bool:
        """真实下载检查完成：stage 已就绪**且**有存在的本地模型文件。

        只看 `stage` 会把 `generated`（已生成、待下载检查）误当就绪；只看文件存在
        又可能拿到半截文件。两个条件同时成立才算 —— 与生产
        `claimAvailability` 的 `stage == .ready && modelPath 存在` 同源。
        """
        return (
            job.get("stage") in ("ready", "claimed")
            and bool(job.get("modelPath"))
            and job.get("modelFileExists") is True
        )

    def wait_wish_ready(self, job_id: str, timeout: float) -> dict | None:
        """轮询 `status.wishJobs`，等到该任务**真的完成下载检查**；超时返回 None。"""
        assert self.host is not None
        deadline = time.monotonic() + timeout
        last: dict = {}
        while time.monotonic() < deadline:
            status = self.host.command("status").get("result", {})
            for candidate in status.get("wishJobs", []):
                if not same_id(candidate.get("id"), job_id):
                    continue
                last = candidate
                if self.wish_download_checked(candidate):
                    return candidate
            time.sleep(2.0)
        if last:
            self.ledger.info(
                "下载检查等待超时时的最后读数", job=last,
                stage=last.get("stage"), modelPath=last.get("modelPath"),
                modelFileExists=last.get("modelFileExists"))
        return None

    def wait_tray_ready(self, object_id: str, timeout: float) -> dict | None:
        """等渲染端把这一件**真的端上托盘**（现场推导 ready，不是命令成功）。

        `claimAvailability` 的 `outputAvailable` 读的正是这条现场结论；没有它，
        领取门不会放行（`notAtMachine`）。等待期间把每次读数写进日志，便于具名诊断。
        """
        assert self.host is not None
        deadline = time.monotonic() + timeout
        last: dict = {}
        while time.monotonic() < deadline:
            status = self.host.command("status").get("result", {})
            last = status
            if (status.get("wishMachineOutputID") == object_id
                    and status.get("wishMachineOutputStatus") == "ready"):
                return status
            time.sleep(1.0)
        self.ledger.info(
            "托盘等待超时时的最后读数",
            wishMachineOutputID=last.get("wishMachineOutputID"),
            wishMachineOutputStatus=last.get("wishMachineOutputStatus"))
        return None

    def wait_claim_ready(self, job_id: str, timeout: float) -> tuple[dict | None, str]:
        """等生产领取门放行（`claimReady`，与工具/界面同一条 `claimAvailability`）。

        返回 `(放行的那条任务, "")` 或 `(None, 最后一条具名原因)`。放行的判据包含
        `activityID == wish_machine.collect`、`phase == loop`、距离 ≤ 0.25 m 与托盘
        可领取 —— 驱动器一条都不替它放宽。
        """
        assert self.host is not None
        deadline = time.monotonic() + timeout
        last_error = ""
        while time.monotonic() < deadline:
            status = self.host.command("status").get("result", {})
            for candidate in status.get("wishJobs", []):
                if not same_id(candidate.get("id"), job_id):
                    continue
                if candidate.get("claimReady") is True:
                    return candidate, ""
                last_error = str(candidate.get("claimError") or "")
            time.sleep(0.5)
        return None, last_error

    def stop_current_activity(self) -> None:
        """收尾当前活动（领取活动跑完后必须先停，`hold_prop` 拒绝活动进行中的挂载）。"""
        if not self._current_activity:
            return
        self.tool("stop_activity", {"reason": "E2E 收尾"})
        self._current_activity = None

    def wait_owned_prop(self, object_id: str, timeout: float) -> dict | None:
        """轮询 `read_owned_props`，等到这一件**真的进入库存**；超时返回 None。

        "读一次空列表就算过了"是上一轮的错：领取与入库是异步的，必须等到物件编号
        出现在 `objects` 里（而不是拿空列表当成功）。
        """
        assert self.host is not None
        deadline = time.monotonic() + timeout
        last: dict = {}
        while time.monotonic() < deadline:
            response = self.tool_quiet("read_owned_props", {})
            last = response
            inner = extract_world_tool_result(response) or {}
            objects = inner.get("objects")
            if isinstance(objects, list) and any(
                isinstance(item, dict) and item.get("object_id") == object_id
                for item in objects
            ):
                self.ledger.record("tool_call", tool="read_owned_props", arguments={},
                                   response=response)
                return response
            time.sleep(1.0)
        self.ledger.record("tool_call", tool="read_owned_props", arguments={}, response=last)
        self.ledger.info("库存等待超时：这一件没有出现在 read_owned_props.objects 里",
                         objectID=object_id)
        return None

    def wait_placement_surfaces(self, timeout: float) -> list[dict]:
        """轮询 `list_placement_surfaces`，等到承托层**真的加载出来**（非空）；超时返回 []。"""
        assert self.host is not None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.tool_quiet("list_placement_surfaces", {})
            surfaces = extract_surfaces(response)
            if surfaces:
                self.ledger.record("tool_call", tool="list_placement_surfaces", arguments={},
                                   response=response)
                return surfaces
            time.sleep(1.0)
        return []

    def run_claim_and_placement(self, job: dict) -> str | None:
        """真实领取 → 实际入库 → 承托层加载 → 摆放/手持（全部走生产工具，不绕权限）。"""
        object_id = str(job.get("objectID") or "")
        job_id = str(job.get("id") or "")
        if not object_id or not job_id:
            self.ledger.blocked("缺少物件编号或任务编号，无法领取", job=job)
            return None
        if job.get("stage") == "claimed" and self.args.existing_wish_id:
            self.ledger.info("恢复已领取任务：本轮不重复验领取，继续核对真实库存与摆放")
            return self.run_owned_placement(object_id)
        # 1) 领取就绪：渲染端先真的把这一件端上托盘（现场推导 ready）。
        tray = self.wait_tray_ready(object_id, timeout=self.args.timeout)
        self.ledger.check(
            tray is not None,
            "产物已下载检查并真的端上托盘（wishMachineOutputStatus=ready）",
            wishMachineOutputID=(tray or {}).get("wishMachineOutputID"),
            wishMachineOutputStatus=(tray or {}).get("wishMachineOutputStatus"))
        if tray is None:
            self.ledger.blocked("托盘没有在期限内就绪，领取未执行")
            return None
        # 2) 用生产活动入口走过去，等领取门真的放行（到取物点、phase=loop、可领取）。
        self.stop_current_activity()
        started = self.tool("start_activity", {"activity_id": WISH_MACHINE_COLLECT})
        self.ledger.check(world_tool_succeeded(started),
                          "居民开始执行 wish_machine.collect（生产活动入口）", result=started)
        if not world_tool_succeeded(started):
            self.ledger.blocked("许愿机领取活动起不来，领取未执行", result=started)
            return None
        self._current_activity = WISH_MACHINE_COLLECT
        ready, claim_error = self.wait_claim_ready(job_id, timeout=self.args.timeout)
        self.ledger.check(
            ready is not None,
            "生产领取门放行（到取物点、phase=loop、托盘可领取）",
            claimError=claim_error, job=ready)
        if ready is None:
            self.stop_current_activity()
            self.ledger.blocked("领取门未在期限内放行，未领取", claimError=claim_error)
            return None
        # 3) 真的领。
        claim = self.tool("claim_wish_output", {"wish_id": job_id})
        self.ledger.info("claim_wish_output", result=claim)
        self.ledger.check(world_tool_succeeded(claim), "claim_wish_output 成功登记领取",
                          result=claim)
        self.stop_current_activity()
        if not world_tool_succeeded(claim):
            self.ledger.blocked("领取工具没有成功，入库与摆放不执行", result=claim)
            return None
        return self.run_owned_placement(object_id)

    def find_placeable_placement(
        self, object_id: str, surfaces: list[dict], layout_revision: int
    ) -> tuple[dict | None, dict | None, str]:
        """用生产 `preview_prop_placement` 在真实承托层里找一个**判据真的放行**的格心。

        上一版固定取 `surfaces[0]`（按承托高度排序的最低层）的格心，那恰好是贴墙的一格，
        于是被真实判据以 `blockedByMesh` 拒绝。**这不是判据错，是选点错**：真实舱体的
        承托层是 3,000+ 个单格，验收要做的是"选一个真的能放的位置"，不是关掉碰撞。

        候选按"离所有格心质心由近到远"排序（从房间中部往外探），逐个交给与落地**完全同源**
        的 `preview_prop_placement`。只有预检放行的候选才会被拿去 `apply_prop_placement`；
        一个都没有时如实具名返回，绝不退回固定格心硬提交。
        """
        cells: list[tuple[dict, float, float]] = []
        for surface in surfaces:
            center = surface.get("center")
            if isinstance(center, dict):
                x, z = center.get("x"), center.get("z")
            elif isinstance(center, list) and len(center) >= 3:
                x, z = center[0], center[2]
            else:
                continue
            if not (isinstance(x, (int, float)) and isinstance(z, (int, float))):
                continue
            cells.append((surface, float(x), float(z)))
        if not cells:
            return None, None, "承托层没有可用的格心"
        center_x = sum(cell[1] for cell in cells) / len(cells)
        center_z = sum(cell[2] for cell in cells) / len(cells)
        cells.sort(key=lambda cell: (cell[1] - center_x) ** 2 + (cell[2] - center_z) ** 2)
        last_reason = ""
        attempted = 0
        for surface, x, z in cells[:PLACEMENT_PROBE_BUDGET]:
            attempted += 1
            placement: dict = {
                "object_id": object_id,
                "surface_id": surface.get("id"),
                "x": x,
                "y": float(surface.get("support_height", 0.0)),
                "z": z,
                "yaw": 0.0,
            }
            preview = self.tool_quiet("preview_prop_placement", placement)
            if world_tool_succeeded(preview):
                self.ledger.record("tool_call", tool="preview_prop_placement",
                                   arguments=dict(placement), response=preview)
                placement["layout_revision"] = layout_revision
                self.ledger.info(
                    f"摆放选点：第 {attempted} 个候选通过生产预检（不改碰撞判据）",
                    surfaceID=surface.get("id"), x=x, z=z)
                return placement, surface, ""
            last_reason = extract_world_tool_code(preview) or str(preview.get("error") or "")
        return None, None, (
            f"在 {attempted} 个候选格心内没有通过生产预检的位置（最后原因：{last_reason}）")

    def run_owned_placement(self, object_id: str) -> str | None:
        # 真的入库：等到这一件出现在 read_owned_props.objects 里。
        owned = self.wait_owned_prop(object_id, timeout=self.args.timeout)
        self.ledger.check(
            owned is not None,
            f"领取后物件真的进入库存（read_owned_props.objects 含 {object_id}）",
            objectID=object_id)
        if owned is None:
            self.ledger.blocked("领取成功但库存里没出现这一件，摆放/手持不执行")
            return None
        self._object_id = object_id
        layout_revision = extract_layout_revision(owned)
        # 5) 承托层真的加载出来（与装修面板无关：世界加载时就备好）。
        surfaces = self.wait_placement_surfaces(timeout=self.args.timeout)
        self.ledger.check(
            bool(surfaces),
            f"承托层已加载（list_placement_surfaces 非空，{len(surfaces)} 层）",
            surfaces=surfaces[:3])
        surface = surfaces[0] if surfaces else None
        if not surface or layout_revision is None:
            self.ledger.blocked("缺少摆放层/版本，摆放与手持未执行",
                                surface=surface, layout_revision=layout_revision)
            return object_id
        placement, surface, reason = self.find_placeable_placement(
            object_id, surfaces, layout_revision)
        if placement is None:
            self.ledger.check(False, "在真实承托层里用生产预检找到可摆放位置",
                              reason=reason, surfaces=surfaces[:3])
            self.ledger.blocked("没有通过真实碰撞/表面判据的可放位置，摆放与手持未执行",
                                reason=reason)
            return object_id
        applied = self.tool("apply_prop_placement", placement)
        self.ledger.check(world_tool_succeeded(applied), "物件已按正式摆放工具落位",
                          result=applied)
        # 摆放会推进布局版本：手持/放回必须用**同一份**最新回执里的版本号。
        owned_after = self.wait_owned_prop(object_id, timeout=min(self.args.timeout, 30))
        revision_after = extract_layout_revision(owned_after) or layout_revision
        held = self.tool("hold_prop", {
            "object_id": object_id, "slot": "rightHand", "layout_revision": revision_after})
        self.ledger.check(world_tool_succeeded(held), "正式手持工具回执", result=held)
        # 手持同样推进版本：放回再读一次，绝不拿旧版本硬提交。
        owned_held = self.tool("read_owned_props", {})
        revision_held = extract_layout_revision(owned_held) or revision_after
        returned = self.tool("return_held_prop", {
            "object_id": object_id, "layout_revision": revision_held})
        self.ledger.check(world_tool_succeeded(returned), "正式放回工具回执", result=returned)
        # 重启前回读"最终摆放事实"：位置 / 承托面 / 朝向 / 是否在手上。重启后逐项对回。
        final = self.tool_quiet("read_owned_props", {})
        self._placement_readback = extract_owned_object(final, object_id)
        self._object_id = object_id
        return object_id

    def tool_quiet(self, name: str, arguments: dict) -> dict:
        """与 `tool` 同一口径，但**不写账本**：用于轮询（等入库/等承托层）。

        控制层 `ok` 在内层世界工具报错时被压成 False（主代理的可读性修复），
        所以等待循环读到的是"命令被拒绝"而不是"命令成功"。
        """
        assert self.host is not None
        response = self.host.command("tool_call", {"name": name, "arguments": arguments},
                                     timeout=self.args.timeout)
        result = response.get("result", {})
        if result.get("isError") or result.get("ok") is False:
            response["ok"] = False
        return response

    def tool(self, name: str, arguments: dict) -> dict:
        response = self.tool_quiet(name, arguments)
        self.ledger.record("tool_call", tool=name, arguments=arguments, response=response)
        return response

    # -- finish --------------------------------------------------------------

    def finish(self) -> int:
        ledger = self.ledger
        summary = {
            "root": str(self.root),
            "passed": ledger.passed,
            "failed": ledger.failed,
            "blocked": ledger.blocked_count,
            "entries": ledger.entries,
        }
        ledger_dir = ROOT / "tmp/e2e-real-app"
        ledger_dir.mkdir(parents=True, exist_ok=True)
        (ledger_dir / "ledger.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        (self.root / "evidence" / "summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\n[e2e-real-app] 通过 {ledger.passed} / 失败 {ledger.failed} / blocked {ledger.blocked_count}")
        print(f"[e2e-real-app] 账本：{ledger_dir / 'ledger.json'}")
        if ledger.failed:
            return 1
        if ledger.blocked_count:
            return 2
        return 0


def extract_layout_revision(owned_response: dict) -> int | None:
    inner = owned_response.get("result", {}).get("result") if owned_response.get("ok") else None
    if isinstance(inner, dict):
        value = inner.get("layout_revision")
        if isinstance(value, (int, float)):
            return int(value)
    return None


def extract_surfaces(surfaces_response: dict) -> list[dict]:
    """`list_placement_surfaces` 回执里的承托层列表（空列表 = 没拿到，不是成功）。"""
    inner = surfaces_response.get("result", {}).get("result") if surfaces_response.get("ok") else None
    if isinstance(inner, dict):
        layers = inner.get("surfaces") or inner.get("layers") or []
        if isinstance(layers, list):
            return [layer for layer in layers if isinstance(layer, dict)]
    return []


def extract_first_surface(surfaces_response: dict) -> dict | None:
    """list_placement_surfaces 回执里的第一层：{id, support_height, center, ...}。"""
    surfaces = extract_surfaces(surfaces_response)
    return surfaces[0] if surfaces else None


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help="已构建的独立测试产物路径")
    parser.add_argument("--build", action="store_true", help="调用 tools/e2e-app-build.sh 先构建")
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--root", help="测试数据根（默认 /tmp/gmgn-e2e-<时间戳>，短到 AF_UNIX 放得下）")
    parser.add_argument("--reuse-root", action="store_true",
                        help="复用已有 root（默认：root 已存在就拒绝覆盖）")
    parser.add_argument("--overwrite-root", action="store_true",
                        help="显式删除并重建已有 root")
    parser.add_argument("--prop-config", help="真实生成服务配置的只读来源")
    parser.add_argument("--avatar-source", action="append", default=None,
                        help="只读的人物包来源（单个包或包目录）；**复制**进测试根，绝不 symlink")
    parser.add_argument("--motion-source", action="append", default=None,
                        help="只读的动作包来源（单个包或包目录）；**复制**进测试根，绝不 symlink")
    parser.add_argument("--stand-motion-id", default=STAND_MOTION_ID,
                        help="显式站姿（idle）动作 ID：测试根只选它，站姿接地判据只认它"
                             f"（默认 {STAND_MOTION_ID}）")
    parser.add_argument("--sit-motion-id", default=SIT_MOTION_ID,
                        help="显式坐姿动作 ID：坐姿判据认它或世界坐姿活动（chair.sit/bunk.rest）"
                             f"（默认 {SIT_MOTION_ID}）")
    parser.add_argument("--asset-image", default=str(DEFAULT_IMAGE),
                        help="只读引用的许愿素材图片")
    parser.add_argument("--prop-name", default="E2E 端到端电视")
    parser.add_argument("--existing-wish-id",
                        help="显式恢复模式：跳过生成，接着验这个已存在的许愿任务"
                             "（**必须**与 --reuse-root 同用，避免重复生成花费；"
                             "本模式只证明「已有任务能接着走完」，不代表全新生成流程已通过）")
    parser.add_argument("--video-url", default=DEFAULT_VIDEO_URL)
    parser.add_argument("--audio-output-sampler",
                        help="可执行的按 PID 限定输出采样工具，用于 HLS 真实开停对照")
    parser.add_argument("--audio-reference-url", default=DEFAULT_AUDIO_REFERENCE_URL,
                        help="非 HLS 声音对照源：公开的 file-based、带音轨 mp4"
                             "（默认 W3C Sintel 预告片）。它只证明采样链可用，"
                             "不把 HLS 那条 blocked 改判。")
    parser.add_argument("--skip-audio-reference", action="store_true",
                        help="跳过非 HLS 声音对照采样（默认在重启恢复后执行）")
    parser.add_argument("--check-audio-reference", action="store_true",
                        help="只读确认 --audio-reference-url 是公开 file-based mp4 且有音轨，"
                             "不启动 App；打印 JSON 后退出（0=可用，2=不可用）")
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--generation-timeout", type=float, default=600)
    parser.add_argument("--chat-timeout", type=float, default=180,
                        help="真实 chat 回合等待终态的秒数（生产提交门 → 对话服务）")
    parser.add_argument("--skip-chat-turn", action="store_true",
                        help="跳过真实 chat 回合验证（默认执行；仅用于明确不要模型轮次的场合）")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.check_audio_reference:
        report = probe_audio_reference(args.audio_reference_url, timeout=min(args.timeout, 60))
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0 if report.get("usable") else 2
    return RealAppE2E(args).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
