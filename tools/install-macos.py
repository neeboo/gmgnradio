#!/usr/bin/env python3
"""Install one macOS bundle and replace its scoped task daemon together."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


@contextlib.contextmanager
def stage(timings, name):
    """Record how long one install stage took, when the caller asked for it.

    `timings` is None for every ordinary install (including the unit tests), so
    this is a no-op unless opt-in profiling is on: the receipt on stdout stays
    byte-identical, and the numbers are reported separately on stderr.
    """
    started = time.monotonic()
    try:
        yield
    finally:
        if timings is not None:
            timings[name] = round(time.monotonic() - started, 3)


# The daemon verification probe (see Runtime.verify) answers an empty
# ``memory_status`` request with ``invalid_memory_status``. That is a
# daemon-identity check — it proves the socket belongs to the freshly started
# helper — not a memory-provider check, so it survives the removal of the
# external VoiceMem provider layer. Fixed, safe failure string: a raw service
# payload must never reach a log, an exception or a receipt.
DAEMON_VERIFY_FAILED = 'New daemon memory interface verification failed'


def _daemon_command_tails(root, sock):
    """The three exact daemon invocations this installer owns.

    Process replacement accepts these command lines and nothing else. A command
    that merely shares this prefix but adds any argument (including a duplicate
    --root/--socket) is a different, untrusted process and must never be
    signalled.
    """
    base = f' --root {root} --socket {sock}'
    return (base,
            base + ' --concurrency 2',
            base + f' --concurrency 2 --legacy-root {root.parent / "PropGeneration"}')


def _daemon_commands(helper, root, sock):
    return {f'{helper}{tail}' for tail in _daemon_command_tails(root, sock)}


def _valid_memory_probe_response(response):
    """Whether a probe reply is the strict shape this installer expects.

    The daemon under verification must answer the empty ``memory_status``
    probe with the ``invalid_memory_status`` error object. Anything else --
    top-level arrays/null/scalars, a missing or non-object ``error``, a wrong
    id -- is an untrusted reply and must fail with a fixed, safe message.
    """
    if not isinstance(response, dict) or response.get('id') != 'install-probe':
        return False
    error = response.get('error')
    return isinstance(error, dict) and error.get('code') == 'invalid_memory_status'


class Runtime:
    def processes(self):
        output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True)
        return [(int(pid), command) for line in output.splitlines()
                for pid, command in [line.strip().split(None, 1)]]

    def stop(self, pid, command, timeout):
        if (pid, command) not in self.processes():
            return
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + timeout
        while (pid, command) in self.processes():
            if time.monotonic() >= deadline:
                raise RuntimeError(f'Process {pid} did not stop; bundle was not replaced')
            time.sleep(.1)

    def start(self, helper, root, sock):
        return subprocess.Popen([str(helper), '--root', str(root), '--socket', str(sock),
                                 '--concurrency', '2', '--legacy-root', str(root.parent / 'PropGeneration')], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)

    def verify(self, child, sock, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError('New daemon exited before verification')
            try:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(min(1, max(.01, deadline - time.monotonic())))
                    connection.connect(str(sock))
                    # Darwin sys/un.h: SOL_LOCAL=0, LOCAL_PEERPID=0x002.
                    # Read before the peer can close after its reply.
                    peer_pid = connection.getsockopt(0, 0x002)
                    connection.sendall(b'{"id":"install-probe","method":"memory_status","params":{}}\n')
                    with connection.makefile('rb') as stream:
                        line = stream.readline(65536)
                    try:
                        response = json.loads(line)
                    except ValueError:
                        # A malformed frame is a fixed failure; the raw payload
                        # must never reach an exception.
                        raise RuntimeError(DAEMON_VERIFY_FAILED) from None
                    # A live child alone does not prove it owns this socket.
                    if peer_pid != child.pid:
                        raise RuntimeError('Daemon socket belongs to a different process')
                if not _valid_memory_probe_response(response):
                    raise RuntimeError(DAEMON_VERIFY_FAILED)
                if child.poll() is not None:
                    raise RuntimeError('New daemon exited after verification')
                return
            except OSError:
                time.sleep(.1)
        raise RuntimeError('New daemon socket verification timed out')

    def stop_child(self, child, timeout):
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=timeout)

def validate(app, require_helper=True):
    try:
        with (app / 'Contents/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError) as error:
        raise RuntimeError(f'Invalid app bundle: {app}') from error
    if info.get('CFBundleIdentifier') != BUNDLE_IDENTIFIER or info.get('CFBundleExecutable') != 'gmgn radio':
        raise RuntimeError('Unexpected application identity')
    for relative in ['Contents/MacOS/gmgn radio', 'Contents/Helpers/gmgn-taskd']:
        if not require_helper and relative.startswith('Contents/Helpers/'):
            continue
        if not (app / relative).is_file() or not os.access(app / relative, os.X_OK):
            raise RuntimeError(f'Missing executable app/helper: {relative}')


def ensure_signature(app, timings=None):
    """仅当签名**不完整**时补一次 ad-hoc 签名，返回是否补过。

    Xcode 的 Debug 产物是 linker-signed：可执行文件本身有签名，但 bundle 资源
    封印对不上，`codesign --verify --deep --strict` 会报
    "code has no resources but signature indicates they must be present"。
    这种 bundle 可能被 macOS 拒绝启动，所以在替换前补签，让装出来的副本自洽。

    反过来，**已经正确签名（含 Developer ID / 公证）的产物绝不能重签**：那会把
    正式签名换成 ad-hoc，等于毁掉分发能力。所以这里只补不覆盖。
    """
    with stage(timings, 'signature.verify_before'):
        verified = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)],
                                  capture_output=True)
    if verified.returncode == 0:
        return False
    with stage(timings, 'signature.resign'):
        resigned = subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)],
                                  capture_output=True)
    if resigned.returncode != 0:
        raise RuntimeError('Installed bundle signature could not be repaired')
    with stage(timings, 'signature.verify_after'):
        recheck = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)],
                                 capture_output=True)
    if recheck.returncode != 0:
        raise RuntimeError('Repaired bundle signature still fails verification')
    return True


# ---------------------------------------------------------------------------
# LaunchServices 注册表：规则是"同一个 bundle id 只允许 /Applications 那份"。
#
# 2026-10-02 本机实测（`lsregister -f` + `-dump` + `mdls` + `mdfind`，探针用一次性
# bundle id，见 tools/test-install-macos.py）：
#   * bundle 是按**结构**认的：`previous.backup`（没有 `.app` 后缀）在 /Applications 里
#     被 `mdls` 认成 `com.apple.application-bundle` —— 它今天没进注册表，只是因为父目录
#     是隐藏目录（Spotlight/`lsregister -f` 都不进隐藏目录）；
#   * 去掉 `Contents/MacOS/<exec>` 的可执行位**没用**：实测 `lsregister -f` 照样注册成功；
#   * **去掉 `Contents/Info.plist` 有用**：没有 plist 就没有 CFBundleIdentifier，
#     dump 里再也不会出现这个 id（`-f` 返回 0，但没有记录）；
#   * **Spotlight 索引本身就会注册**：把一个新 bundle 放进 `$HOME` 下不碰
#     `lsregister`，30 s 内 `mdls` 认得它、dump 里也多了一条记录。这解释了为什么
#     `make build` 末尾的 `-u` 会被"撤销"——文件名还在，mdworker 索引它时会再注册一次；
#   * 目录名带 `.noindex` 后缀的子树不会进索引，也不会被注册（实测）。
# 结论：只要**文件还在**、且在一个会被索引的位置，注销就是暂时的；根治要么删文件，
# 要么把产物放进 `.noindex` 路径（那是 DerivedData 迁移，不在本次落点）。
# ---------------------------------------------------------------------------
LSREGISTER = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
              'LaunchServices.framework/Support/lsregister')
# 本项目唯一的应用身份（`validate` 用它判定"这是不是我们的 bundle"）。
BUNDLE_IDENTIFIER = 'ai.gmgn.radio'
SEALED_INFO_PLIST = 'Info.plist.rollback'
ROLLBACK_NOTES = 'ROLLBACK.txt'


def lsregister_path(override=None):
    """`lsregister` 的路径，可覆盖 —— 测试必须能注入替身。

    2026-10-02：`tools/test-install-macos.py` 以前通过 `install()` 直接调用**真机**
    `lsregister`：把注册表里 ai.gmgn.radio 的其它路径（包含 `/Applications` 那份正式
    安装）逐个注销，再把临时 fixture 注册进去；fixture 目录随测试清理消失，留下一条
    指向不存在路径的死注册，而正式安装被注销。测试永远不该碰真机注册表。
    `GMGN_LSREGISTER=<路径>` 或调用参数都能替换掉它。
    """
    return Path(override or os.environ.get('GMGN_LSREGISTER') or LSREGISTER)


def bundle_identifier(app):
    """bundle 的 CFBundleIdentifier。

    读不出来（目录已不在/没有 plist）时返回本项目固定的身份而不是 None：调用方
    （dedupe/装机收尾）要的语义是"清掉不属于正规安装的同 id 注册"，即使正规安装
    本身暂时不在磁盘上，这个 id 也仍然是我们必须独占的那一个。
    """
    try:
        with (Path(app) / 'Contents/Info.plist').open('rb') as handle:
            return plistlib.load(handle).get('CFBundleIdentifier') or BUNDLE_IDENTIFIER
    except (OSError, ValueError):
        return BUNDLE_IDENTIFIER


def _lsregister(lsregister, arguments, timeout=60):
    return subprocess.run([str(lsregister), *arguments], capture_output=True, text=True,
                          timeout=timeout)


def registered_paths(app, lsregister=None):
    """当前注册到 `app` 这个 bundle id 的**所有**路径（可能不止一条）。

    `lsregister -dump` 的每条记录里 `path:` 出现在 `identifier:` **之前**（实测），
    所以不能"先看到 id 再收 path" —— 必须按 `----------` 分隔的区块整体判断。
    """
    app = Path(app)
    identifier = bundle_identifier(app)
    dump = _lsregister(lsregister_path(lsregister), ['-dump'])
    paths = []
    for block in dump.stdout.split('\n----------'):
        if identifier not in block:
            continue
        for line in block.splitlines():
            stripped = line.strip()
            if not stripped.startswith('path:'):
                continue
            # dump 里路径后面跟着注册表的句柄，例如
            # `path:   /Applications/gmgn radio.app (0x7b2c)` —— 不去掉尾巴
            # 就会去注销一个不存在的文件名，静默失败（2026-09-29 实测）。
            text = stripped.split('path:', 1)[1].strip()
            if text.endswith(')') and ' (0x' in text:
                text = text[:text.rindex(' (0x')]
            paths.append(Path(text))
    return paths


def audit_single_registration(app, lsregister=None):
    """可复核的判据：这个 bundle id 只注册了 `app` 这一条。

    返回 `(ok, others)`：`others` 是除 `app` 之外仍注册着的路径。读操作，不改注册表，
    所以可以随时跑（`tools/dedupe-app-registrations.py --check`）。
    """
    app = Path(app)
    try:
        others = sorted({path for path in registered_paths(app, lsregister) if path != app})
    except Exception:
        return False, []
    return not others, others


def ensure_single_registration(app, extra_paths=(), lsregister=None, verify=True):
    """按"除正规安装外全部注销"这条**规则**收敛注册表，而不是清一次。

    真机上曾出现两个 "gmgn radio"：一份是 /Applications 里的正式安装，另一份是
    构建产物路径。这里把同一 bundle id 的**其它每一条**注册逐个注销，再注册本安装。

    顺序与死注册：
      * 文件还在的注册 `lsregister -u` 就能清掉；
      * 路径已经不在磁盘上的（产物被删后留下的）`-u` 会失败 —— 只能重建数据库；
      * `extra_paths`（安装工作区/回滚备份）**无论 dump 里有没有**都注销一次：它们是
        同一 bundle id 的第二份候选，不该出现在任何"打开方式"列表里。
    尽力而为：任何一步失败都不影响安装结果，返回值告诉调用方还剩什么。
    """
    app = Path(app)
    lsregister = lsregister_path(lsregister)
    try:
        stale = [path for path in registered_paths(app, lsregister) if path != app]
    except Exception:
        stale = []
    for path in [*stale, *(Path(p) for p in extra_paths)]:
        if path == app:
            continue
        try:
            _lsregister(lsregister, ['-u', str(path)], timeout=30)
        except Exception:
            pass
    # `lsregister -u` 对**已经不在磁盘上**的路径是拒绝的（它会说
    # "Bundle node not found on disk"），所以死注册只能靠重建数据库清掉。
    # 正规安装自己也算：装机被删/回滚掉之后，它那条记录同样清不掉。
    #
    # 2026-09-30：这里过去是"只要 stale 非空就重建"，而装机时最常见的 stale
    # 恰恰是 **xcodebuild 刚注册、文件还在** 的构建产物（`lsregister -u` 对它
    # 有效）。为它重建整个 LaunchServices 数据库，每次装机白付约 8 s
    # （实测 registration 阶段 15.0 s 对 6.9 s）。现在只有"文件已不在磁盘上"
    # 的死注册才触发重建。
    if any(not path.exists() for path in [*stale, app]):
        try:
            _lsregister(lsregister, ['-kill', '-r', '-domain', 'local',
                                     '-domain', 'system', '-domain', 'user'], timeout=120)
        except Exception:
            pass
    try:
        _lsregister(lsregister, ['-f', str(app)], timeout=30)
    except Exception:
        pass
    if not verify:
        return []
    try:
        return [path for path in registered_paths(app, lsregister) if path != app]
    except Exception:
        return []


def seal_rollback_backup(backup, lsregister=None):
    """把回滚备份改成**不可注册**的形态：整个 bundle 去掉 Info.plist（只改名）。

    为什么是这个形态（2026-10-02 本机实测）：
      * 改扩展名/目录名挡不住：`previous.backup` 明明没有 `.app` 后缀，`mdls` 在
        /Applications 里照样把它认成 `com.apple.application-bundle`。它目前没被注册
        只是因为父目录是隐藏目录 —— 一旦备份出现在别的位置（或被 `open`/`mdimport`
        碰一次），名字救不了；
      * 去掉可执行位无效：实测 `lsregister -f` 仍然注册成功（探针 C）；
      * 打包成 zip 有效，但每次装机都要压一份上百 MB 的产物（安装循环是热点路径，
        见 034ea94），而且失败回滚要多一步解压 —— 回滚是安全关键路径，动作越少越好。
    改名是零拷贝且**不可注册**：没有 Info.plist 就没有 CFBundleIdentifier，
    LaunchServices 读不出这是哪个 app（实测 `-f` 之后 dump 里没有该 id 的记录），
    所以它不可能再变成第二个 "gmgn radio"。字节一个没动，回滚只是把名字改回来。
    """
    backup = Path(backup)
    plist = backup / 'Contents/Info.plist'
    if not plist.is_file():
        return False
    try:
        plist.rename(backup / 'Contents' / SEALED_INFO_PLIST)
    except OSError:
        return False
    try:
        (backup / ROLLBACK_NOTES).write_text(
            '这是 gmgn radio 的回滚备份（装机时替换下来的上一份 /Applications/gmgn radio.app）。\n'
            '为了不让 Spotlight/LaunchServices 把它当成第二个 "gmgn radio"，它的\n'
            f'Contents/Info.plist 被改名为 Contents/{SEALED_INFO_PLIST} —— 没有 Info.plist 的\n'
            '目录不可能被注册成这个 bundle id 的应用。**文件内容一个字没改**。\n'
            '\n'
            '回滚（两条 mv，不需要重新编译）：\n'
            f'  mv "{backup}/Contents/{SEALED_INFO_PLIST}" "{backup}/Contents/Info.plist"\n'
            '  # 先退出正在运行的 gmgn radio，然后：\n'
            '  mv "/Applications/gmgn radio.app" "/Applications/previous.gmgn-radio.app"\n'
            f'  mv "{backup}" "/Applications/gmgn radio.app"\n'
            '  # 需要的话再注册一次：\n'
            '  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/gmgn radio.app"\n',
            encoding='utf-8')
    except OSError:
        pass
    try:
        _lsregister(lsregister_path(lsregister), ['-u', str(backup)], timeout=30)
    except Exception:
        pass
    return True


def restore_rollback_backup(backup):
    """`seal_rollback_backup` 的逆操作（回滚/测试用）。"""
    backup = Path(backup)
    sealed = backup / 'Contents' / SEALED_INFO_PLIST
    if not sealed.is_file():
        return False
    try:
        sealed.rename(backup / 'Contents/Info.plist')
    except OSError:
        return False
    with contextlib.suppress(OSError):
        (backup / ROLLBACK_NOTES).unlink()
    return True


def seal_install_workspaces(parent, lsregister=None):
    """把 `/Applications/.gmgn-install-*` 里遗留的回滚备份逐个"封口"。

    这些目录是隐藏目录（`ls` 看不见、Spotlight 不进），所以它们**当前**并没有被注册；
    但里面躺着的是一份同 bundle id 的完整 bundle，谁把它索引/点开一次就会变成
    第二个图标。按"只有一个正规路径"这条规则，它们不该保持可注册形态。
    """
    sealed = []
    for workspace in sorted(Path(parent).glob('.gmgn-install-*')):
        if seal_rollback_backup(workspace / 'previous.backup', lsregister):
            sealed.append(workspace / 'previous.backup')
    return sealed


def prune_install_workspaces(parent, keep=None, lsregister=None):
    """删除历次安装留下的临时工作区，只保留 keep 那一个（= 最近一次可回滚的备份）。

    2026-09-29：每次 `make install` 都会在 `/Applications` 下留一个
    `.gmgn-install-XXXX/previous.backup`（一份完整的 app 副本），而**从来没有清理过** ——
    真机上攒到 19 个、2.4 GB，而且这些目录里各装着一个 app bundle，会被 Spotlight/
    LaunchServices 当成候选，于是"打开方式"里出现第二个 gmgn radio。
    安装成功时保留一个（回滚用），其余一律删掉；删不掉不算安装失败。

    2026-10-02：删之前先**封口**（去掉 Info.plist）—— 万一 rmtree 失败（权限、占用），
    留下的也是不可注册的形态，而不是又一份候选 app。
    """
    keep = Path(keep) if keep is not None else None
    for candidate in Path(parent).glob('.gmgn-install-*'):
        if keep is not None and candidate == keep:
            continue
        seal_rollback_backup(candidate / 'previous.backup', lsregister)
        try:
            shutil.rmtree(candidate)
        except OSError:
            pass


def install(source, destination, root, runtime=None, timeout=15, timings=None, lsregister=None):
    source, destination, root = (Path(p).expanduser().resolve() for p in (source, destination, root))
    if source == destination or source in destination.parents or destination in source.parents:
        raise RuntimeError('Source and destination must be separate bundles')
    with stage(timings, 'validate_source'):
        validate(source)
    if destination.exists():
        with stage(timings, 'validate_destination'):
            validate(destination, require_helper=False)
    runtime = runtime or Runtime()
    sock = root / 'taskd.sock'
    destination.parent.mkdir(parents=True, exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix='.gmgn-install-', dir=destination.parent))
    staged, backup = workspace / 'staged.backup', workspace / 'previous.backup'
    child = None
    swapped = False
    try:
        with stage(timings, 'copy_bundle'):
            shutil.copytree(source, staged, symlinks=True)
        with stage(timings, 'validate_staged'):
            validate(staged)
        # 先补签暂存副本再替换：装出去的 bundle 一定是自洽的；中途失败也不会
        # 留下一个签坏了的正式安装。
        with stage(timings, 'signature'):
            signature_repaired = ensure_signature(staged, timings)
        with stage(timings, 'scan_processes'):
            rows = runtime.processes()
        executables = {str(app / 'Contents/MacOS/gmgn radio') for app in (source, destination)}
        apps = [(pid, command) for pid, command in rows if command in executables]
        with stage(timings, 'stop_app'):
            for pid, command in apps:
                runtime.stop(pid, command, timeout)
        commands = set()
        for app in (source, destination):
            commands.update(_daemon_commands(app / 'Contents/Helpers/gmgn-taskd', root, sock))
        with stage(timings, 'stop_daemons'):
            daemons = [(pid, command) for pid, command in runtime.processes() if command in commands]
            for pid, command in daemons:
                runtime.stop(pid, command, timeout)
        with stage(timings, 'backup_rename'):
            if destination.exists():
                destination.rename(backup)
        try:
            with stage(timings, 'swap_rename'):
                staged.rename(destination)
        except Exception:
            if backup.exists():
                backup.rename(destination)
            raise
        swapped = True
        with stage(timings, 'daemon_start'):
            child = runtime.start(destination / 'Contents/Helpers/gmgn-taskd', root, sock)
        with stage(timings, 'daemon_verify'):
            runtime.verify(child, sock, timeout)
        # 外部 VoiceMem provider 层已拆除：这里不再向 daemon 发送任何 endpoint/
        # token，安装器也不再读取任何记忆 provider 环境变量。安装只负责替换
        # bundle、拉起 daemon 并验证套接字归属；记忆模块在 daemon 内部自行工作。
        #
        # 安装成功后的三项收尾（都不影响返回值，也都不算失败）：
        #   1. LaunchServices 里**只留这一条**注册（规则，不是清一次：别的路径逐个注销）；
        #   2. 本次回滚备份"封口"——去掉 Info.plist，让它不可能再被注册成第二个图标
        #      （字节不动，回滚只需把名字改回来，见 seal_rollback_backup）；
        #   3. 历次安装的工作区只留本次这一个（回滚用），其余封口后删掉。
        with stage(timings, 'registration'):
            remaining = ensure_single_registration(destination, extra_paths=[backup],
                                                   lsregister=lsregister)
        with stage(timings, 'seal_backup'):
            sealed = seal_rollback_backup(backup, lsregister) if backup.exists() else False
        with stage(timings, 'prune_workspaces'):
            prune_install_workspaces(destination.parent, keep=workspace, lsregister=lsregister)
        return {'destination': str(destination), 'backup': str(backup) if backup.exists() else None,
                'daemon_verified': True, 'signature_repaired': signature_repaired,
                'app_stopped': bool(apps), 'open_app_manually': True,
                # 可复核的判据：装机结束时注册表里这个 bundle id 只剩正规安装这一条。
                # False 说明还有别的路径（构建产物/临时副本/死注册）占着同一个 id。
                'registration_clean': not remaining,
                # 回滚备份的新形态：目录还在、字节没动，只是 Contents/Info.plist 被改名成
                # Contents/Info.plist.rollback（因此不可注册）。回滚步骤写在同目录 ROLLBACK.txt。
                'sealed_backup': str(backup) if sealed else None}
    except Exception as error:
        if swapped:
            try:
                if child is not None:
                    runtime.stop_child(child, timeout)
                destination.rename(workspace / 'failed.backup')
                if backup.exists():
                    backup.rename(destination)
            except Exception as rollback_error:
                raise RuntimeError(f'Install failed: {error}; rollback incomplete: {rollback_error}; recovery: {workspace}') from error
        raise RuntimeError(f'Install failed: {error}; recovery files: {workspace}') from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, default=Path('/Applications/gmgn radio.app'))
    parser.add_argument('--root', type=Path, default=Path.home() / 'Library/Application Support/gmgn radio/TaskService')
    # 排查装机慢用的可观测性开关，默认关闭：stdout 的回执保持逐字段不变
    # （tools/test-install-macos.py 会逐字段比较它），计时走 stderr。
    # 也可以直接 `GMGN_INSTALL_TIMING=1 make install`。
    parser.add_argument('--timing', action='store_true',
                        default=os.environ.get('GMGN_INSTALL_TIMING') == '1',
                        help='report per-stage install timings on stderr')
    args = parser.parse_args()
    timings = {} if args.timing else None
    started = time.monotonic()
    try:
        receipt = install(args.source, args.destination, args.root, timings=timings)
    except Exception as error:
        if timings is not None:
            timings['total'] = round(time.monotonic() - started, 3)
            print(json.dumps({'timings': timings, 'failed': True}), file=sys.stderr)
        parser.exit(1, f'{error}\n')
    if timings is not None:
        timings['total'] = round(time.monotonic() - started, 3)
        print(json.dumps({'timings': timings, 'failed': False}), file=sys.stderr)
    print(json.dumps(receipt, ensure_ascii=False))


if __name__ == '__main__':
    main()
