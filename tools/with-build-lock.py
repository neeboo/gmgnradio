#!/usr/bin/env python3
"""构建互斥闸：同一个工作区/DerivedData 上，同一时刻只跑一个重型编译进程。

**为什么需要这个**（2026-10-01 事故）：7 个 agent 同时在同一个 DerivedData 上跑
`make build`，10 核机器被 15 路并行 `swift-frontend` 打到负载 36+，并且反复出现

    error: unable to attach DB: error: accessing build database
    ".../apps/macos/Build.noindex/Build/Intermediates.noindex/XCBuildData/build.db":
    database is locked Possibly there are two concurrent builds running in the
    same filesystem location.

xcodebuild 的 build database 是 DerivedData 里**独占**的 SQLite 文件，并发 attach
必然互锁 —— 于是构建"莫名失败"，而 agent 会把这种失败误判成自己刚改的代码有问题。
闸门把"并发"换成"排队"，**只做互斥**：不改任何编译参数、产物路径或验证语义。

用法
----
    python3 tools/with-build-lock.py --lock <锁文件> [--timeout 秒] -- <命令> [参数...]

行为
----
* 拿不到锁就**排队等待**（不是失败退出）：第一次等待时打印 `等待另一个构建完成…`，
  之后每隔 `--wait-notice` 秒（默认 15 s）打印一次已经等了多久；
* 等待超过 `--timeout` 秒（默认 3600 s，也可用环境变量 `BUILD_LOCK_TIMEOUT` 覆盖）
  时打印锁的持有者并以退出码 **75**（EX_TEMPFAIL）退出。75 是"临时不可用"，
  **不是编译失败**，避免 agent 把它当成代码错误；等待上限只影响"等多久报警"，
  不影响任何构建结果；
* 拿到锁后运行目标命令，并把它的 stdout/stderr/退出码/信号原样透传 ——
  `make` 看到的和没加闸门时一样。

锁的生命周期（重要）
--------------------
锁是 `fcntl.flock` 加在锁文件上的 advisory lock，由**本脚本进程**持有，
目标命令的子进程**不继承**这个 fd（Python 建的 fd 默认 FD_CLOEXEC）。

为什么不让 `xcodebuild` 自己持有：`lsof` 实测 Xcode 的构建服务
(`SWBBuildService`) 会长期驻留、并且自己打开 `XCBuildData/build.db` 等一堆
DerivedData 里的 fd。如果锁 fd 被 exec 继承进去，一旦被某个长驻子进程留着，
闸门就**永久**锁死（后续每次构建都只能等到超时）。由本脚本持有则锁的生命周期
严格等于"这一次构建"，长驻服务不可能把闸门占住。

代价（已知且有意接受）：如果**只 kill 本脚本进程**（`kill -9 <wrapper>`）而它的
构建子进程还活着，锁会提前释放 —— 这是内核语义，用户态无法阻止。正常路径
（Ctrl-C、超时清理、按进程组 kill、构建自然结束）都不会触发：本脚本收到
SIGINT/SIGTERM/SIGHUP 时会把它转给构建子进程，并**等构建真正退出后**才释放锁。

锁文件永不删除
--------------
持有进程一退出（正常结束、被 Ctrl-C、被 kill、机器重启）锁就自动释放，所以
**不存在**需要清理的"死锁文件"；本脚本也因此**从不删除任何文件**（不 `rm`、
不 `unlink`、不 `rmdir`）。锁文件本身留在 gitignored 的 DerivedData 里。

可重入
------
如果环境变量 `BUILD_LOCK_HELD` 等于本锁的绝对路径（说明当前进程已经在闸门里，
例如 make 递归调用），直接执行命令、不重复取锁，避免自己把自己锁死。
"""

from __future__ import annotations

import errno
import fcntl
import os
import signal
import subprocess
import sys
import time

EX_USAGE = 2
EX_TEMPFAIL = 75
EX_NOTFOUND = 127

DEFAULT_TIMEOUT = 3600.0
DEFAULT_NOTICE = 15.0
HELD_ENV = "BUILD_LOCK_HELD"

_OPTION_KEYS = {
    "--lock": "lock",
    "--timeout": "timeout",
    "--wait-notice": "notice",
    "--label": "label",
}


def warn(message: str) -> None:
    sys.stderr.write("[build-lock] %s\n" % message)
    sys.stderr.flush()


def die(message: str, code: int = EX_USAGE) -> None:
    warn(message)
    sys.exit(code)


def parse_args(argv):
    """把 `[选项...] -- 命令...` 拆开。命令必须在 `--` 之后，避免歧义。"""
    options = {"lock": None, "timeout": None, "notice": None, "label": None}
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--":
            return options, argv[index + 1:]
        if argument in _OPTION_KEYS:
            if index + 1 >= len(argv):
                die("%s 需要一个取值" % argument)
            options[_OPTION_KEYS[argument]] = argv[index + 1]
            index += 2
            continue
        for prefix, key in _OPTION_KEYS.items():
            if argument.startswith(prefix + "="):
                options[key] = argument[len(prefix) + 1:]
                break
        else:
            die("无法识别的参数 %r（要执行的命令必须放在 `--` 之后）" % argument)
        index += 1
    die("缺少 `-- <命令>`；用法见 tools/with-build-lock.py 顶部说明")


def resolve_timeout(raw):
    if raw is None or raw == "":
        raw = os.environ.get("BUILD_LOCK_TIMEOUT")
    if raw is None or raw == "":
        return DEFAULT_TIMEOUT
    try:
        value = float(raw)
    except (TypeError, ValueError):
        die("timeout 不是数字：%r" % (raw,))
    if value <= 0:
        die("timeout 必须是正数：%r" % (raw,))
    return value


def resolve_notice(raw):
    if raw is None or raw == "":
        return DEFAULT_NOTICE
    try:
        value = float(raw)
    except (TypeError, ValueError):
        die("wait-notice 不是数字：%r" % (raw,))
    return value if value > 0 else DEFAULT_NOTICE


def holder_description(lock_path):
    """读出锁文件里持有者自己写的 pid/命令，仅用于诊断。"""
    try:
        with open(lock_path, "r", encoding="utf-8", errors="replace") as handle:
            info = handle.read().strip()
    except OSError:
        return "持有者信息不可读"
    return info or "持有者尚未写入信息"


def write_holder_info(descriptor, text):
    try:
        os.ftruncate(descriptor, 0)
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.write(descriptor, text.encode("utf-8", "replace"))
        os.fsync(descriptor)
    except OSError:
        pass  # 诊断信息写不进去不影响互斥本身。


def open_lock_file(lock_path):
    directory = os.path.dirname(os.path.abspath(lock_path))
    if directory:
        # DerivedData 目录第一次构建时可能还不存在。只创建目录，不碰已有内容。
        try:
            os.makedirs(directory, exist_ok=True)
        except OSError as error:
            die("无法创建锁文件目录 %s：%s" % (directory, error))
    try:
        # O_CREAT 但绝不 O_TRUNC：锁文件是长期复用的，内容只在取到锁之后重写。
        return os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as error:
        die("无法打开锁文件 %s：%s" % (lock_path, error))


def acquire(lock_path, timeout, notice, label, command):
    """取到锁返回 fd；已经在闸门里则返回 None；超时直接退出 75。"""
    resolved = os.path.realpath(lock_path)
    held = os.environ.get(HELD_ENV)
    if held and os.path.realpath(held) == resolved:
        warn("已在构建闸门内（%s），直接执行：%s" % (resolved, label))
        return None

    descriptor = open_lock_file(lock_path)

    def try_lock():
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as error:
            if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
                return False
            die("取锁失败：%s" % error)

    deadline = time.monotonic() + timeout
    announced = False
    next_notice = 0.0
    while not try_lock():
        now = time.monotonic()
        if not announced:
            warn(
                "等待另一个构建完成…（锁 %s；%s）"
                % (resolved, holder_description(lock_path))
            )
            announced = True
            next_notice = now + notice
        if now >= deadline:
            warn(
                "超时：等待 %.0f s 仍未获得构建锁（本次目标 %s，锁 %s）"
                % (timeout, label, resolved)
            )
            warn("当前持有者：%s" % holder_description(lock_path))
            warn(
                "这不是代码/编译错误：是另一个重型构建长时间没结束。"
                "等待上限可用 BUILD_LOCK_TIMEOUT=<秒> 调整后重试。"
            )
            sys.exit(EX_TEMPFAIL)
        if now >= next_notice:
            warn("已等待 %.0f s（上限 %.0f s）…" % (timeout - (deadline - now), timeout))
            next_notice = now + notice
        time.sleep(min(1.0, max(0.05, deadline - now)))

    waited = timeout - (deadline - time.monotonic())
    write_holder_info(
        descriptor,
        "pid=%d label=%s started=%s cmd=%s"
        % (
            os.getpid(),
            label,
            time.strftime("%Y-%m-%d %H:%M:%S"),
            " ".join(command),
        ),
    )
    if announced:
        warn("已获得构建锁（等待 %.0f s），开始 %s" % (waited, label))
    return descriptor


def run_under_lock(descriptor, lock_path, label, command):
    """在持有锁的状态下运行命令；退出码/信号原样透传。"""
    if descriptor is not None:
        # 让 make 的递归调用（$(MAKE)）知道自己已经在闸门里，不要重复取锁。
        os.environ[HELD_ENV] = os.path.realpath(lock_path)

    try:
        child = subprocess.Popen(command)
    except OSError as error:
        die("无法执行 %r：%s" % (command[0], error), EX_NOTFOUND)

    if descriptor is not None:
        write_holder_info(
            descriptor,
            "pid=%d child=%d label=%s started=%s cmd=%s"
            % (
                os.getpid(),
                child.pid,
                label,
                time.strftime("%Y-%m-%d %H:%M:%S"),
                " ".join(command),
            ),
        )

    forwarded = []

    def forward(signum, _frame):
        forwarded.append(signum)
        try:
            child.send_signal(signum)
        except OSError:
            pass

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(signum, forward)
        except (ValueError, OSError):
            pass

    # 关键：必须等构建子进程真正退出，锁的生命周期才等于"这一次构建"。
    status = child.wait()
    if status < 0:
        sys.exit(128 - status)
    sys.exit(status)


def main(argv):
    options, command = parse_args(argv)
    if not options["lock"]:
        die("必须用 --lock <锁文件> 指定锁")
    if not command:
        die("`--` 之后需要一条命令")
    lock_path = options["lock"]
    label = options["label"] or command[0]
    timeout = resolve_timeout(options["timeout"])
    notice = resolve_notice(options["notice"])

    descriptor = acquire(lock_path, timeout, notice, label, command)
    run_under_lock(descriptor, lock_path, label, command)


if __name__ == "__main__":
    main(sys.argv[1:])
