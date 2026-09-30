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
    if info.get('CFBundleIdentifier') != 'ai.gmgn.radio' or info.get('CFBundleExecutable') != 'gmgn radio':
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


def prune_install_workspaces(parent, keep=None):
    """删除历次安装留下的临时工作区，只保留 keep 那一个（= 最近一次可回滚的备份）。

    2026-09-29：每次 `make install` 都会在 `/Applications` 下留一个
    `.gmgn-install-XXXX/previous.backup`（一份完整的 app 副本），而**从来没有清理过** ——
    真机上攒到 19 个、2.4 GB，而且这些目录里各装着一个 app bundle，会被 Spotlight/
    LaunchServices 当成候选，于是"打开方式"里出现第二个 gmgn radio。
    安装成功时保留一个（回滚用），其余一律删掉；删不掉不算安装失败。
    """
    keep = Path(keep) if keep is not None else None
    for candidate in Path(parent).glob('.gmgn-install-*'):
        if keep is not None and candidate == keep:
            continue
        try:
            shutil.rmtree(candidate)
        except OSError:
            pass


def ensure_single_registration(app):
    """让这个 bundle id 在 LaunchServices 里**只剩本安装这一条**注册。

    真机上曾出现两个 "gmgn radio"：一份是 /Applications 里的正式安装，另一份是
    构建产物路径（文件早删了，注册还留着）。这里把同一 bundle id 的其它注册逐个注销，
    再注册本安装。尽力而为：任何一步失败都不影响安装结果。
    """
    app = Path(app)
    lsregister = ('/System/Library/Frameworks/CoreServices.framework/Frameworks/'
                  'LaunchServices.framework/Support/lsregister')
    try:
        with (app / 'Contents/Info.plist').open('rb') as handle:
            bundle_id = plistlib.load(handle).get('CFBundleIdentifier')
        if not bundle_id:
            return False
        dump = subprocess.run([lsregister, '-dump'], capture_output=True, text=True, timeout=60)
        # `lsregister -dump` 的每条记录里 `path:` 出现在 `bundle id:` **之前**（实测），
        # 所以不能"先看到 bundle id 再收 path" —— 必须按 `-----` 分隔的区块整体判断。
        stale = []
        for block in dump.stdout.split('\n----------'):
            if bundle_id not in block:
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
                path = Path(text)
                if path != app:
                    stale.append(path)
        for path in stale:
            subprocess.run([lsregister, '-u', str(path)], capture_output=True, timeout=30)
        # `lsregister -u` 对**已经不在磁盘上**的路径是拒绝的（dump 里会写
        # "Bundle node not found on disk"），所以死注册用 `-u` 清不掉 ——
        # 实测只能重建数据库。只在确实有死注册时才做。
        #
        # 2026-09-30：这里过去是"只要 stale 非空就重建"，而装机时最常见的 stale
        # 恰恰是 **xcodebuild 刚注册、文件还在** 的构建产物（`lsregister -u` 对它
        # 有效）。为它重建整个 LaunchServices 数据库，每次装机白付约 8 s
        # （实测 registration 阶段 15.0 s 对 6.9 s）。现在只有"文件已不在磁盘上"
        # 的死注册才触发重建。
        if any(not path.exists() for path in stale):
            subprocess.run([lsregister, '-kill', '-r', '-domain', 'local',
                            '-domain', 'system', '-domain', 'user'],
                           capture_output=True, timeout=120)
        subprocess.run([lsregister, '-f', str(app)], capture_output=True, timeout=30)
        return True
    except Exception:
        return False


def install(source, destination, root, runtime=None, timeout=15, timings=None):
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
        # 安装成功后的两项收尾（都不影响返回值，也都不算失败）：LaunchServices 里
        # 只留这一条注册；历次安装的工作区只留本次这一个（回滚用），其余删掉。
        with stage(timings, 'registration'):
            ensure_single_registration(destination)
        with stage(timings, 'prune_workspaces'):
            prune_install_workspaces(destination.parent, keep=workspace)
        return {'destination': str(destination), 'backup': str(backup) if backup.exists() else None,
                'daemon_verified': True, 'signature_repaired': signature_repaired,
                'app_stopped': bool(apps), 'open_app_manually': True}
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
