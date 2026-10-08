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
import http.client
import importlib.util
import uuid
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


# Probe the authenticated HTTP authority, without logging service payloads.
DAEMON_VERIFY_FAILED = 'New daemon HTTP interface verification failed'
APPLICATION_EXECUTABLES = frozenset(('gmgn radio', 'gmgn-gpui-app'))
SCREEN_LINK_HELPER_LOCK = Path(__file__).parent / 'helpers/screen-link-helpers.lock.json'


def _bundled_media_arguments(helper):
    """Use the same pinned helpers and argument order as production bootstrap."""
    directory = Path(helper).parent
    names = ('yt-dlp', 'deno')
    if not any((directory / name).exists() or (directory / (name + '.sha256')).exists()
               for name in names):
        return []  # Historical bundles did not ship screen-link helpers.
    spec = importlib.util.spec_from_file_location(
        'installer_screen_link_helpers', Path(__file__).with_name('bundle-screen-link-helper.py'))
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    lock = verifier.load_lock(SCREEN_LINK_HELPER_LOCK)
    entries = {entry['name']: entry for entry in lock['helpers']}
    arguments = []
    for name, flag in (('yt-dlp', '--media-helper'), ('deno', '--media-deno')):
        target = directory / name
        manifest = directory / (name + '.sha256')
        if target.is_symlink() or manifest.is_symlink():
            raise RuntimeError('Invalid bundled media helper')
        digest = verifier.verify_installed(entries[name], directory)
        if manifest.read_text(encoding='utf-8').split() != [digest, name]:
            raise RuntimeError('Invalid bundled media helper manifest')
        arguments.extend([flag, str(target), flag + '-sha256', digest])
    return arguments


def _daemon_command_tails(root, sock):
    """The exact historical daemon invocations this installer owns.

    Process replacement accepts these command lines and nothing else. A command
    that merely shares this prefix but adds any argument (including a duplicate
    --root/--endpoint-file) is a different, untrusted process and must never be
    signalled.
    """
    base = f' --root {root} --endpoint-file {sock}'
    return (base,
            base + ' --concurrency 2',
            base + f' --concurrency 2 --legacy-root {root.parent / "PropGeneration"}')


def _daemon_commands(helper, root, sock):
    commands = {f'{helper}{tail}' for tail in _daemon_command_tails(root, sock)}
    media = _bundled_media_arguments(helper)
    if media:
        # PropTaskDaemonClient appends legacy-root AFTER the media arguments;
        # WorldAuthorityClient omits legacy-root. Do not accept permutations.
        base = f'{helper} --root {root} --endpoint-file {sock} --concurrency 2'
        media_command = base + ' ' + ' '.join(media)
        commands.update((media_command,
                         media_command + f' --legacy-root {root.parent / "PropGeneration"}'))
    return commands


def _valid_health_probe_response(response):
    return isinstance(response, dict) and response == {"version": 2, "transport": "http"}


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
        return subprocess.Popen([str(helper), '--root', str(root), '--endpoint-file', str(sock),
                                 '--concurrency', '2', *_bundled_media_arguments(helper),
                                 '--legacy-root', str(root.parent / 'PropGeneration')], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True)

    def verify(self, child, sock, timeout):
        deadline = time.monotonic() + timeout
        descriptor = Path(sock)
        expected = _daemon_commands(Path(child.args[0]), descriptor.parent, descriptor)
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError('New daemon exited before verification')
            connection = None
            try:
                endpoint = json.loads(descriptor.read_text())
                host, port = endpoint['address'].rsplit(':', 1)
                if endpoint.get('version') != 2 or host != '127.0.0.1' or not 0 < int(port) < 65536:
                    raise RuntimeError(DAEMON_VERIFY_FAILED)
                if uuid.UUID(endpoint['token']).version != 4:
                    raise RuntimeError(DAEMON_VERIFY_FAILED)
                # Retain exact process scope checks; a PID alone cannot prove
                # that the installed helper owns this root and descriptor.
                rows = self.processes()
                if not any(pid == child.pid and command in expected for pid, command in rows):
                    raise RuntimeError('Daemon HTTP endpoint belongs to a different process')
                owners = subprocess.check_output(['/usr/sbin/lsof', '-nP', '-a', '-iTCP:' + port,
                                                  '-sTCP:LISTEN', '-t'], text=True).splitlines()
                if str(child.pid) not in owners:
                    raise RuntimeError('Daemon HTTP endpoint belongs to a different process')
                connection = http.client.HTTPConnection(host, int(port), timeout=min(1, max(.01, deadline - time.monotonic())))
                connection.request('GET', '/health', headers={'Authorization': 'Bearer ' + endpoint['token']})
                response = connection.getresponse()
                body = response.read(65537)
                if response.status != 200 or len(body) > 65536:
                    raise RuntimeError(DAEMON_VERIFY_FAILED)
                if not _valid_health_probe_response(json.loads(body)):
                    raise RuntimeError(DAEMON_VERIFY_FAILED)
                if child.poll() is not None:
                    raise RuntimeError('New daemon exited after verification')
                return
            except FileNotFoundError:
                time.sleep(.1)
            except (ValueError, KeyError, TypeError, http.client.HTTPException):
                raise RuntimeError(DAEMON_VERIFY_FAILED) from None
            except (OSError, subprocess.CalledProcessError):
                time.sleep(.1)
            finally:
                if connection is not None:
                    connection.close()
        raise RuntimeError('New daemon HTTP verification timed out')

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
    if not isinstance(info, dict):
        raise RuntimeError('Unexpected application identity')
    executable = info.get('CFBundleExecutable')
    unity = info.get('CFBundleIdentifier') == 'ai.gmgn.unity-sample.player' and executable == 'GMGN Unity Sample'
    if not unity and (info.get('CFBundleIdentifier') != BUNDLE_IDENTIFIER or not isinstance(executable, str) or executable not in APPLICATION_EXECUTABLES):
        raise RuntimeError('Unexpected application identity')
    if unity:
        executable_path = app / 'Contents/MacOS' / executable
        if executable_path.is_symlink() or not executable_path.is_file() or not executable_path.resolve().is_relative_to(app.resolve()) or not os.access(executable_path, os.X_OK):
            raise RuntimeError('Missing Unity executable')
        if require_helper:
            spec = importlib.util.spec_from_file_location('unity_product_metadata', Path(__file__).with_name('unity-product-metadata.py'))
            verifier = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(verifier)
            try:
                verifier.verify(app)
            except (OSError, ValueError, KeyError) as error:
                raise RuntimeError('Invalid Unity product manifest') from error
            # Pinned public-link verification uses the existing command; no download.
            subprocess.run([sys.executable, str(Path(__file__).with_name('bundle-screen-link-helper.py')), '--destination', str(app / 'Contents/Helpers'), '--verify-only', '--include', 'deno'], check=True, capture_output=True)
        return executable
    for relative in [f'Contents/MacOS/{executable}', 'Contents/Helpers/gmgn-taskd',
                     'Contents/Helpers/gmgn-mcpd']:
        if not require_helper and relative.startswith('Contents/Helpers/'):
            continue
        path = app / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(app.resolve()) or not os.access(path, os.X_OK):
            raise RuntimeError(f'Missing executable app/helper: {relative}')
    if require_helper:
        for name in ('gmgn-taskd', 'gmgn-mcpd'):
            manifest = app / 'Contents/Helpers' / (name + '.sha256')
            if manifest.is_symlink() or not manifest.is_file() or not manifest.resolve().is_relative_to(app.resolve()):
                raise RuntimeError(f'Invalid helper manifest: {manifest}')
        spec = importlib.util.spec_from_file_location('gmgn_helper_manifest', Path(__file__).with_name('verify-helper-manifest.py'))
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        report = verifier.verify(app)
        if not report['ok']:
            raise RuntimeError('Invalid helper manifest: ' + '; '.join(report['errors']))
    return executable


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
    if dump.returncode != 0:
        raise RuntimeError('LaunchServices registration readback failed')
    paths = []
    for block in dump.stdout.split('\n----------'):
        identifiers = [line.strip().split(':', 1)[1].strip()
                       for line in block.splitlines()
                       if line.strip().startswith('identifier:')]
        if identifier not in identifiers:
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
      * 路径已经不在磁盘上的记录可能无法注销，保留在返回值里；
      * `extra_paths`（安装工作区/回滚备份）**无论 dump 里有没有**都注销一次：它们是
        同一 bundle id 的第二份候选，不该出现在任何"打开方式"列表里。
    注销尽力而为，返回值报告残留；验证读回失败则抛出错误，不宣称清理成功。
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
    try:
        _lsregister(lsregister, ['-f', str(app)], timeout=30)
    except Exception:
        pass
    if not verify:
        return []
    # 读回失败必须暴露错误，不能用空列表声称注册清理成功。
    return [path for path in registered_paths(app, lsregister) if path != app]


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
        source_executable = validate(source)
    destination_executable = None
    if destination.exists():
        with stage(timings, 'validate_destination'):
            destination_executable = validate(destination, require_helper=False)
    runtime = runtime or Runtime()
    sock = root / 'taskd.endpoint.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix='.gmgn-install-', dir=destination.parent))
    staged, backup = workspace / 'staged.backup', workspace / 'previous.backup'
    child = None
    swapped = False
    try:
        with stage(timings, 'copy_bundle'):
            # Preserve macOS code-signature metadata on signed text helpers and
            # manifests as well as Mach-O signatures. copytree loses those
            # extended attributes and needlessly invalidates a valid release.
            subprocess.run(['/usr/bin/ditto', '--rsrc', '--extattr', str(source), str(staged)],
                           check=True, capture_output=True)
        with stage(timings, 'validate_staged'):
            validate(staged)
        # 先补签暂存副本再替换：装出去的 bundle 一定是自洽的；中途失败也不会
        # 留下一个签坏了的正式安装。
        with stage(timings, 'signature'):
            signature_repaired = ensure_signature(staged, timings)
        with stage(timings, 'validate_signed_staged'):
            validate(staged)
        with stage(timings, 'scan_processes'):
            rows = runtime.processes()
        executables = {str(source / 'Contents/MacOS' / source_executable)}
        if destination_executable is not None:
            executables.add(str(destination / 'Contents/MacOS' / destination_executable))
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
