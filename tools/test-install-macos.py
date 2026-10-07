#!/usr/bin/env python3
import importlib.util
import contextlib
import hashlib
import io
import os
import plistlib
from pathlib import Path
import tempfile
import json
import http.server
import uuid
import shutil
import subprocess
import sys
import threading
import time
import unittest
import unittest.mock as mock

SCRIPT = Path(__file__).with_name('install-macos.py')
spec = importlib.util.spec_from_file_location('installer', SCRIPT)
module = importlib.util.module_from_spec(spec) if SCRIPT.exists() else None
if module:
    spec.loader.exec_module(module)

DEDUPE_SCRIPT = Path(__file__).with_name('dedupe-app-registrations.py')
dedupe_spec = importlib.util.spec_from_file_location('dedupe', DEDUPE_SCRIPT)
dedupe = importlib.util.module_from_spec(dedupe_spec) if DEDUPE_SCRIPT.exists() else None
if dedupe:
    dedupe_spec.loader.exec_module(dedupe)

# `lsregister` 的替身。**测试永远不许碰真机注册表**：2026-10-02 之前
# `install()` 会在收尾时调用真的 `lsregister`，于是 `make test-install` 把注册表里
# ai.gmgn.radio 的其它路径（包含 /Applications 那份正式安装）逐个注销，再把临时
# fixture 注册进去；fixture 目录随测试清理消失，留下一条指向不存在路径的死注册。
# 这个替身把真机实测的三条语义照搬过来，好让"死注册只有重建数据库能清"这条逻辑
# 真的被测到：
#   * `-u <p>`：只有 p **还在磁盘上**才能注销（真机上文件已消失时它会报
#     "Bundle node not found on disk"）；
#   * `-kill -r`：重建数据库 = 按磁盘现状重新扫描，消失的路径就没了；
#   * `-f <p>`：注册 p。
LSREGISTER_STUB = '''#!/usr/bin/env python3
"""lsregister 替身（测试用）：只动自己旁边的状态文件，绝不碰真机注册表。"""
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
state_file = here / 'lsregister-paths.txt'
journal = here / 'lsregister-journal.txt'
paths = state_file.read_text(encoding='utf-8').splitlines() if state_file.exists() else []


def save():
    state_file.write_text(''.join(path + '\\n' for path in paths), encoding='utf-8')


def log(text):
    with journal.open('a', encoding='utf-8') as handle:
        handle.write(text + '\\n')


arguments = sys.argv[1:]
status = 0
if arguments and arguments[0] == '-dump':
    for path in paths:
        sys.stdout.write('----------\\n'
                         f'path:                       {path} (0x1)\\n'
                         'name:                       gmgn radio\\n'
                         'identifier:                 ai.gmgn.radio\\n')
elif arguments and arguments[0] == '-kill':
    log('kill')
    paths[:] = [path for path in paths if pathlib.Path(path).exists()]
    save()
elif arguments and arguments[0] == '-u':
    log('-u ' + ' '.join(arguments[1:]))
    target = arguments[1]
    if pathlib.Path(target).exists() and target in paths:
        paths.remove(target)
        save()
    else:
        status = 1
elif arguments and arguments[0] == '-f':
    log('-f ' + ' '.join(arguments[1:]))
    target = arguments[1]
    if target not in paths:
        paths.append(target)
        save()
else:
    log(' '.join(arguments))
raise SystemExit(status)
'''



class Runtime:
    def __init__(self):
        self.rows = []
        self.events = []
        self.timeout = False
        self.valid = True
        self.after_stop = []

    def processes(self):
        return self.rows

    def stop(self, pid, command, timeout):
        self.events.append(('stop', pid))
        if self.timeout:
            raise RuntimeError('stop timeout')
        self.rows = [row for row in self.rows if row[0] != pid] + self.after_stop
        self.after_stop = []

    def start(self, helper, root, sock):
        self.events.append(('start', str(helper)))
        return 99

    def verify(self, child, sock, timeout):
        self.events.append(('verify', child))
        if not self.valid:
            raise RuntimeError('unknown_method')

    def stop_child(self, child, timeout):
        self.events.append(('stop_child', child))


class DaemonChild:
    def __init__(self, pid):
        self.pid = pid

    def poll(self):
        return None


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(module, 'unified installer does not exist')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.source = base / 'build' / 'gmgn radio.app'
        self.dest = base / 'Applications' / 'gmgn radio.app'
        self.root = base / 'Task Service'
        for app, marker in [(self.source, 'new'), (self.dest, 'old')]:
            (app / 'Contents/Helpers').mkdir(parents=True)
            (app / 'Contents/MacOS').mkdir()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'ai.gmgn.radio', 'CFBundleExecutable': 'gmgn radio'}))
            for relative in ['Contents/Helpers/gmgn-taskd', 'Contents/Helpers/gmgn-mcpd', 'Contents/MacOS/gmgn radio']:
                p = app / relative
                p.write_text(marker)
                p.chmod(0o755)
        self.runtime = Runtime()
        # 注册表替身：整套测试都不许调用真机 lsregister（见 LSREGISTER_STUB）。
        self.bin = base / 'bin'
        self.bin.mkdir()
        self.lsregister = self.bin / 'lsregister'
        self.lsregister.write_text(LSREGISTER_STUB, encoding='utf-8')
        self.lsregister.chmod(0o755)
        self.lsregister_state = self.bin / 'lsregister-paths.txt'
        self.lsregister_journal = self.bin / 'lsregister-journal.txt'
        self.registered(self.dest)

    # -- 注册表替身的读写口 -------------------------------------------------

    def registered(self, *paths):
        """把替身的注册表设成这些路径（真机 dump 里 path 在 identifier 之前，替身照排）。"""
        self.lsregister_state.write_text(''.join(f'{path}\n' for path in paths), encoding='utf-8')

    def registrations(self):
        return self.lsregister_state.read_text(encoding='utf-8').splitlines() \
            if self.lsregister_state.exists() else []

    def journal(self):
        return self.lsregister_journal.read_text(encoding='utf-8').splitlines() \
            if self.lsregister_journal.exists() else []

    def run_install(self):
        return module.install(self.source, self.dest, self.root, runtime=self.runtime,
                              lsregister=self.lsregister)

    def test_missing_helper_never_stops(self):
        (self.source / 'Contents/Helpers/gmgn-taskd').unlink()
        with self.assertRaisesRegex(RuntimeError, 'helper'):
            self.run_install()
        self.assertEqual(self.runtime.events, [])

    def test_same_bundle_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'separate'):
            module.install(self.source, self.source, self.root, runtime=self.runtime)
        self.assertEqual(self.runtime.events, [])

    def test_helper_spawned_during_app_stop_is_stopped(self):
        self.runtime.rows = [(1, str(self.dest / 'Contents/MacOS/gmgn radio'))]
        self.runtime.after_stop = [(2, f'{self.dest}/Contents/Helpers/gmgn-taskd --root {self.root} --endpoint-file {self.root}/taskd.endpoint.json --concurrency 2')]
        self.run_install()
        self.assertEqual(self.runtime.events[:2], [('stop', 1), ('stop', 2)])

    def test_old_bundle_without_helper_is_upgradable(self):
        (self.dest / 'Contents/Helpers/gmgn-taskd').unlink()
        self.run_install()
        self.assertEqual((self.dest / 'Contents/Helpers/gmgn-taskd').read_text(), 'new')

    def test_symlinks_preserved(self):
        (self.source / 'Contents/link').symlink_to('Helpers')
        self.run_install()
        self.assertTrue((self.dest / 'Contents/link').is_symlink())

    def test_probe_checks_actual_authenticated_http_response(self):
        class Child:
            pid = os.getpid()
            args = ['/test/gmgn-taskd']
            def poll(self):
                return None
        secret = 'fixture-secret'
        sensitive = 'https://memory.example/v1/status?token=fixture-secret&scope=install'
        fixed = module.DAEMON_VERIFY_FAILED
        cases = {
            'http_health': ({'version': 2, 'transport': 'http'}, None),
            'old_health': ({'version': 1, 'transport': 'tcp'}, fixed),
            'response_array': ([], fixed),
            'response_null': (None, fixed),
            'malformed_body': (b'not-json', fixed),
            'health_with_secret': ({'version': 2, 'transport': sensitive + secret}, fixed),
            'wrong_peer': ({'version': 2, 'transport': 'http'}, 'different process'),
            'wrong_command': ({'version': 2, 'transport': 'http'}, 'different process'),
            'unauthorized': ({'version': 2, 'transport': 'http'}, fixed),
        }
        for name, (reply, expected) in cases.items():
            with self.subTest(case=name):
                token = str(uuid.uuid4())
                class Handler(http.server.BaseHTTPRequestHandler):
                    def log_message(self, *args):
                        pass
                    def do_GET(handler):
                        self.assertEqual(handler.path, '/health')
                        self.assertEqual(handler.headers['Authorization'], 'Bearer ' + token)
                        payload = reply if isinstance(reply, bytes) else json.dumps(reply).encode()
                        handler.send_response(401 if name == 'unauthorized' else 200)
                        handler.send_header('Content-Length', str(len(payload)))
                        handler.end_headers()
                        handler.wfile.write(payload)
                server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                path = Path(self.temp.name) / 'probe.endpoint.json'
                path.write_text(json.dumps({'version': 2, 'address': '127.0.0.1:' + str(server.server_port), 'token': token}))
                child = Child()
                command = next(iter(module._daemon_commands(Path(child.args[0]), path.parent, path)))
                rows = [(child.pid, command + (' --foreign' if name == 'wrong_command' else ''))]
                owners = str(child.pid + (1 if name == 'wrong_peer' else 0)) + '\n'
                try:
                    with mock.patch.object(module.Runtime, 'processes', return_value=rows), mock.patch.object(module.subprocess, 'check_output', return_value=owners):
                        if expected is None:
                            module.Runtime().verify(child, path, 1)
                        else:
                            with self.assertRaises(RuntimeError) as raised:
                                module.Runtime().verify(child, path, 1)
                            message = str(raised.exception)
                            if expected == fixed:
                                self.assertEqual(fixed, message)
                            else:
                                self.assertIn(expected, message)
                            for leaked in [secret, 'memory.example', '?token=', 'scope=install']:
                                self.assertNotIn(leaked, message)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=2)

    def test_real_scoped_process_term_and_identity_recheck(self):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'])
        self.addCleanup(lambda: child.poll() is None and child.terminate())
        runtime = module.Runtime()
        command = dict(runtime.processes())[child.pid]
        runtime.stop(child.pid, 'wrong identity', .1)
        self.assertIsNone(child.poll())
        runtime.stop(child.pid, command, 1)
        child.wait(timeout=1)
        self.assertIsNotNone(child.returncode)

    def test_real_process_stop_timeout_does_not_escalate(self):
        child = subprocess.Popen([sys.executable, '-c',
            'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print("ready",flush=True); time.sleep(2)'],
            stdout=subprocess.PIPE, text=True)
        self.assertEqual(child.stdout.readline().strip(), 'ready')
        runtime = module.Runtime()
        command = dict(runtime.processes())[child.pid]
        try:
            with self.assertRaisesRegex(RuntimeError, 'did not stop'):
                runtime.stop(child.pid, command, .1)
            self.assertIsNone(child.poll())
        finally:
            child.wait(timeout=3)
            child.stdout.close()

    def test_scoped_order_without_launching_app(self):
        helper = self.dest / 'Contents/Helpers/gmgn-taskd'
        self.runtime.rows = [(1, str(self.dest / 'Contents/MacOS/gmgn radio')),
                             (2, f'{helper} --root {self.root} --endpoint-file {self.root}/taskd.endpoint.json --concurrency 2'),
                             (3, f'{helper} --root /other --endpoint-file /other/taskd.endpoint.json --concurrency 2')]
        self.run_install()
        self.assertEqual([e[0] for e in self.runtime.events], ['stop', 'stop', 'start', 'verify'])
        self.assertEqual(self.runtime.events[:2], [('stop', 1), ('stop', 2)])
        self.assertEqual((self.dest / 'Contents/Helpers/gmgn-taskd').read_text(), 'new')

    def test_timeout_keeps_old_bundle(self):
        self.runtime.rows = [(1, str(self.dest / 'Contents/MacOS/gmgn radio'))]
        self.runtime.timeout = True
        with self.assertRaisesRegex(RuntimeError, 'timeout'):
            self.run_install()
        self.assertEqual((self.dest / 'Contents/Helpers/gmgn-taskd').read_text(), 'old')

    def test_failed_verification_rolls_back_and_does_not_open(self):
        self.runtime.valid = False
        with self.assertRaisesRegex(RuntimeError, 'unknown_method'):
            self.run_install()
        self.assertEqual((self.dest / 'Contents/Helpers/gmgn-taskd').read_text(), 'old')
        self.assertEqual([e[0] for e in self.runtime.events], ['start', 'verify', 'stop_child'])

    def test_install_failure_never_reports_success(self):
        self.dest.parent.chmod(0o555)
        self.addCleanup(self.dest.parent.chmod, 0o755)
        with self.assertRaises(OSError):
            self.run_install()
        self.assertEqual(self.runtime.events, [])

    # -- 外部 VoiceMem provider 配置已整体移除 ------------------------------

    def receipt_fields(self, receipt):
        # backup / sealed_backup 是临时路径；signature_repaired 取决于**源产物**的签名
        # 状态（本测试的 fixture 是带可执行位的文本文件，必然需要补签），三者都不参与
        # 逐字段比较。签名与回滚备份各另有专门的断言。
        return {key: value for key, value in receipt.items()
                if key not in ('backup', 'signature_repaired', 'sealed_backup')}

    def test_installed_bundle_signature_verifies(self):
        """装出去的 bundle 必须通过严格验签。

        Xcode 的 Debug 产物是 linker-signed：可执行文件有签名，但 bundle 资源
        封印对不上（"code has no resources but signature indicates they must be
        present"），macOS 可能因此拒绝启动。安装器必须把这种产物补成自洽的。

        这里断言**结果**而不是"是否补过"：源产物本来就签好的环境不该被重签，
        所以不能要求 signature_repaired 恒为真。
        """
        receipt = self.run_install()
        self.assertIn('signature_repaired', receipt)
        result = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(self.dest)],
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_valid_signature_is_left_alone(self):
        """已经正确签名的产物不得被重签 —— 那会把正式签名（Developer ID/公证）
        换成 ad-hoc，等于毁掉分发能力。

        fixture 必须用**真实 Mach-O**：文本文件当可执行体时，codesign 只能把签名
        放进扩展属性，而 `shutil.copytree` 不保留扩展属性，暂存副本必然验签失败、
        每次都触发补签 —— 那样这条测试就永远测不到"不重签"这个分支。Mach-O 的
        签名是嵌在文件里的，复制不会丢，才测得到。
        """
        echo = Path('/bin/echo').read_bytes()
        for relative in ['Contents/Helpers/gmgn-taskd', 'Contents/Helpers/gmgn-mcpd',
                         'Contents/MacOS/gmgn radio']:
            target = self.source / relative
            target.unlink()
            # 只写字节、不抄标志：copy2 会连 /bin/echo 的受限文件标志一起抄，
            # 触发 Operation not permitted。Mach-O 的内容本身就够了。
            target.write_bytes(echo)
            target.chmod(0o755)
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(self.source)],
                       check=True, capture_output=True)
        verified = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(self.source)],
                                  capture_output=True)
        self.assertEqual(verified.returncode, 0, verified.stderr.decode())
        receipt = self.run_install()
        self.assertFalse(receipt['signature_repaired'])

    def test_install_never_reads_memory_provider_variables(self):
        """GMGN_MEMORY_* 不再被读取：部分/完整/垃圾取值都不能改变安装行为。

        旧行为是"部分配置必须在任何落盘前报 incomplete"，所以这里对同一个安装
        分别注入部分配置、完整配置和垃圾配置，回执必须逐字段相同（回执本身也
        不再有 memory_configured / missing_memory_variables 这类字段）。
        """
        baseline = self.receipt_fields(self.run_install())
        self.assertEqual(baseline, {
            'destination': str(self.dest),
            'daemon_verified': True,
            'app_stopped': False,
            'open_app_manually': True,
            # 装机收尾的可复核判据：注册表里这个 bundle id 只剩正规安装这一条。
            'registration_clean': True,
        })
        envs = [
            {'GMGN_MEMORY_COMPACTION_ENDPOINT': 'https://compaction.example'},
            {'GMGN_MEMORY_COMPACTION_ENDPOINT': 'https://compaction.example',
             'GMGN_MEMORY_COMPACTION_TOKEN': 'compaction-fixture-token',
             'GMGN_MEMORY_COMPACTION_MODEL': 'compaction-fixture-model',
             'GMGN_MEMORY_EMBEDDING_ENDPOINT': 'http://127.0.0.1:9',
             'GMGN_MEMORY_EMBEDDING_TOKEN': 'embedding-fixture-token'},
            {'GMGN_MEMORY_EMBEDDING_TOKEN': 'garbage token with spaces',
             'GMGN_MEMORY_COMPACTION_MODEL': ''},
        ]
        for env in envs:
            with self.subTest(env=sorted(env)):
                with mock.patch.dict(os.environ, env, clear=False):
                    receipt = self.receipt_fields(self.run_install())
                self.assertEqual(receipt, baseline)

    def test_provider_configuration_surface_is_gone(self):
        """模块级正面断言：provider 变量、配置函数与相关常量都不存在了。"""
        for name in ['MEMORY_PROVIDER_VARIABLES', 'MEMORY_STATUS_SCOPE',
                     'MEMORY_INCOMPLETE', 'MEMORY_CONFIGURE_FAILED',
                     'read_memory_configuration', 'require_complete_memory_configuration',
                     'configure_memory_only', 'configure_daemon_memory',
                     'LIBPROC_PATH', 'PROC_PIDPATHINFO_MAXSIZE']:
            self.assertFalse(hasattr(module, name), name)
        # 安装器源码里不再出现任何 GMGN_MEMORY_*（也没有只读它们的代码路径）。
        self.assertNotIn('GMGN_MEMORY', SCRIPT.read_text(encoding='utf-8'))

    def test_configure_memory_only_flag_is_rejected(self):
        """--configure-memory-only 与"只配置记忆"这条路一起删除；--source 必需。

        两种情况都在 argparse 阶段失败（exit 2），因此不会触碰任何真实进程或
        /Applications。
        """
        for arguments in (['--configure-memory-only'], []):
            with self.subTest(arguments=arguments):
                result = subprocess.run([sys.executable, str(SCRIPT), *arguments],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn('error', result.stderr)

    # -- LaunchServices：规则是"同一个 bundle id 只允许正规安装那一条" ----------

    def test_registration_rule_unregisters_every_other_path(self):
        """除正规安装外**每一条**注册都要注销 —— 不只是构建产物那一个。

        这里同时注入三种"另一个 gmgn radio"：构建产物、装机留下的回滚备份，
        以及一条文件已经消失的死注册（删产物之后留下的那种）。前两条 `-u` 能清掉，
        死注册只能靠重建数据库 —— 判据是收敛完之后注册表里只剩正规安装。
        """
        product = self.bin / 'Products' / 'Release' / 'gmgn radio.app'
        (product / 'Contents').mkdir(parents=True)
        (product / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleIdentifier': 'ai.gmgn.radio'}))
        backup = self.bin / '.gmgn-install-abcd' / 'previous.backup'
        (backup / 'Contents').mkdir(parents=True)
        (backup / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleIdentifier': 'ai.gmgn.radio'}))
        dead = self.bin / 'gone' / 'gmgn radio.app'      # 故意不创建：文件已消失
        self.lsregister_journal.unlink(missing_ok=True)
        self.registered(product, self.dest, backup, dead)

        remaining = module.ensure_single_registration(self.dest, extra_paths=[backup],
                                                      lsregister=self.lsregister)

        unregistered = [line for line in self.journal() if line.startswith('-u ')]
        self.assertEqual(set(unregistered),
                         {f'-u {product}', f'-u {backup}', f'-u {dead}'})
        # 顺序：先把能注销的注销掉，再重建数据库清死注册，最后把正规安装注册回来。
        self.assertLess(self.journal().index('kill'), len(self.journal()) - 1)
        self.assertEqual(self.journal()[-1], f'-f {self.dest}')
        self.assertEqual(remaining, [])
        self.assertEqual(self.registrations(), [str(self.dest)])
        ok, others = module.audit_single_registration(self.dest, self.lsregister)
        self.assertTrue(ok, others)

    def test_dead_registration_survives_unregister_and_needs_a_rebuild(self):
        """文件已消失的注册 `-u` 清不掉（真机是 "Bundle node not found on disk"）。"""
        dead = self.bin / 'gone' / 'gmgn radio.app'
        self.registered(self.dest, dead)
        module.ensure_single_registration(self.dest, lsregister=self.lsregister)
        self.assertIn('kill', self.journal())
        self.assertEqual(self.registrations(), [str(self.dest)])

    def test_audit_catches_injected_duplicate_with_a_fail_message(self):
        """注入一份同 id 的副本 ⇒ 判据必须抓住，并且 FAIL 原话要能指名道姓。"""
        injected = self.bin / 'injected' / 'gmgn radio.app'
        (injected / 'Contents').mkdir(parents=True)
        (injected / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleIdentifier': 'ai.gmgn.radio'}))
        self.registered(self.dest, injected)

        ok, others = module.audit_single_registration(self.dest, self.lsregister)
        self.assertFalse(ok)
        self.assertEqual([str(path) for path in others], [str(injected)])

        # `--check` 的 FAIL 原话：真机 APP 路径不变，但注册表换成替身
        # （GMGN_LSREGISTER 就是给这件事留的注入点），所以测试既端到端又不碰真机。
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {'GMGN_LSREGISTER': str(self.lsregister)}):
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(dedupe.main(['--check']), 1)
        message = stderr.getvalue()
        self.assertIn('FAIL: 注册表里', message)
        self.assertIn(str(injected), message)
        self.assertIn('文件仍在', message)

        # 死注册的说法要不一样：它不产生图标，但仍然是同一 id 的第二条。
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            dedupe.fail([self.bin / 'gone' / 'gmgn radio.app'])
        self.assertIn('文件已消失（死注册，只能靠重建数据库清掉）', stderr.getvalue())

    def test_audit_and_check_are_read_only(self):
        """`--check` 不改注册表，也不删任何文件。"""
        product = self.bin / 'Products' / 'Release' / 'gmgn radio.app'
        (product / 'Contents').mkdir(parents=True)
        (product / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleIdentifier': 'ai.gmgn.radio'}))
        self.registered(self.dest, product)
        before = self.journal()
        stderr = io.StringIO()
        with mock.patch.dict(os.environ, {'GMGN_LSREGISTER': str(self.lsregister)}):
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(dedupe.main(['--check', '--products', str(self.bin)]), 1)
        self.assertEqual(self.registrations(), [str(self.dest), str(product)])
        self.assertTrue(product.exists())
        self.assertEqual(self.journal(), before)
        self.assertIn('FAIL:', stderr.getvalue())

    def test_sealed_backup_is_not_a_bundle_and_restores_byte_for_byte(self):
        """封口只改 Info.plist 的名字：字节一个不动，回滚是改回来。"""
        backup = self.bin / 'rollback' / 'previous.backup'
        (backup / 'Contents/MacOS').mkdir(parents=True)
        (backup / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleIdentifier': 'ai.gmgn.radio'}))
        (backup / 'Contents/MacOS/gmgn radio').write_bytes(b'\x00binary-payload\xff')
        (backup / 'Contents/MacOS/gmgn radio').chmod(0o755)
        before = tree_digest(backup)

        self.assertTrue(module.seal_rollback_backup(backup, self.lsregister))
        self.assertFalse((backup / 'Contents/Info.plist').exists())
        self.assertTrue((backup / 'Contents/Info.plist.rollback').is_file())
        notes = backup / 'ROLLBACK.txt'
        self.assertIn('Info.plist.rollback', notes.read_text(encoding='utf-8'))
        # 形态上不再是应用：没有 Info.plist 就没有 CFBundleIdentifier 可注册。
        # 断言的是"**字节**一个没动"，名字只从 Info.plist 变成 Info.plist.rollback。
        after = tree_digest(backup, ignore={notes.name})
        self.assertEqual(sorted(after.values()), sorted(before.values()))
        self.assertEqual(set(after) - set(before), {'Contents/Info.plist.rollback'})
        self.assertEqual(set(before) - set(after), {'Contents/Info.plist'})
        # 幂等：再封一次不报错、也不改变结果。
        self.assertFalse(module.seal_rollback_backup(backup, self.lsregister))

        self.assertTrue(module.restore_rollback_backup(backup))
        self.assertEqual(tree_digest(backup), before)
        self.assertEqual(module.bundle_identifier(backup), 'ai.gmgn.radio')
        self.assertFalse(notes.exists())

    def test_install_seals_the_rollback_backup_and_leaves_it_restorable(self):
        """装机收尾：注册表只剩正规安装；回滚备份被"封口"但字节还在、还能回滚。

        回滚能力是红线：这里断言备份里的**上一份**产物（fixture 写的是 "old"）一个字节
        没变，而且 ROLLBACK.txt 给出了把 Info.plist 改回来的确切命令。
        """
        self.lsregister_journal.unlink(missing_ok=True)
        receipt = self.run_install()

        self.assertTrue(receipt['registration_clean'])
        self.assertEqual(receipt['destination'], str(self.dest))
        backup = Path(receipt['sealed_backup'])
        self.assertEqual(receipt['backup'], str(backup))
        self.assertTrue(backup.is_dir(), '回滚备份目录必须还在')
        self.assertEqual((backup / 'Contents/MacOS/gmgn radio').read_text(), 'old')
        self.assertFalse((backup / 'Contents/Info.plist').exists())
        self.assertTrue((backup / 'Contents/Info.plist.rollback').is_file())
        self.assertIn(f'mv "{backup}/Contents/Info.plist.rollback"',
                      (backup / 'ROLLBACK.txt').read_text(encoding='utf-8'))
        # 注册表里没留下备份路径（真机上它本来也没被注册，但规则要求无条件注销一次）。
        self.assertEqual(self.registrations(), [str(self.dest)])
        self.assertIn(f'-u {backup}', self.journal())

        # 回滚：改回名字之后就是一份完整的、可启动的上一版安装。
        module.restore_rollback_backup(backup)
        self.assertEqual(module.bundle_identifier(backup), 'ai.gmgn.radio')
        self.assertEqual((backup / 'Contents/Helpers/gmgn-taskd').read_text(), 'old')

    def test_install_seals_leftover_workspaces_before_pruning_them(self):
        """历史工作区（prune 的目标）在删除之前先封口：万一删不掉，留下的也不可注册。"""
        leftover = self.dest.parent / '.gmgn-install-zzzz'
        (leftover / 'previous.backup/Contents/MacOS').mkdir(parents=True)
        (leftover / 'previous.backup/Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleIdentifier': 'ai.gmgn.radio'}))
        kept = self.dest.parent / '.gmgn-install-kept'
        (kept / 'previous.backup/Contents').mkdir(parents=True)
        (kept / 'previous.backup/Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleIdentifier': 'ai.gmgn.radio'}))

        module.prune_install_workspaces(self.dest.parent, keep=kept, lsregister=self.lsregister)

        self.assertFalse((leftover / 'previous.backup/Contents/Info.plist').exists())
        self.assertTrue((kept / 'previous.backup/Contents/Info.plist').exists())


@unittest.skipUnless(os.environ.get('GMGN_LSREGISTER_INTEGRATION') == '1',
                     '真机注册表注入测试：GMGN_LSREGISTER_INTEGRATION=1 才跑（会临时注入一份同 id 的副本）')
class RealRegistryInjectionTests(unittest.TestCase):
    """在**真机**注册表上注入一份同 id 的副本，判据必须抓住 —— 然后自己收拾干净。

    默认不跑（要真注册表、要 Spotlight 配合），但它是"注入必须能被抓住"这条要求的
    可复核形式：`GMGN_LSREGISTER_INTEGRATION=1 python3 tools/test-install-macos.py`。
    """

    def test_injected_duplicate_of_the_installed_app_is_caught(self):
        canonical = Path('/Applications/gmgn radio.app')
        lsregister = module.lsregister_path()
        if not (canonical / 'Contents/Info.plist').is_file():
            self.skipTest('/Applications 里没有正式安装，注入测试没有意义')

        probe = Path(tempfile.mkdtemp(prefix='gmgn-dup-probe-', dir=str(Path.home())))
        duplicate = probe / 'gmgn radio.app'
        try:
            (duplicate / 'Contents/MacOS').mkdir(parents=True)
            (duplicate / 'Contents/Info.plist').write_bytes(
                (canonical / 'Contents/Info.plist').read_bytes())      # 同一个 bundle id
            # 只写字节、不抄标志：copy2 会连 /bin/echo 的受限文件标志一起抄，
            # 触发 Operation not permitted（同 test_valid_signature_is_left_alone）。
            (duplicate / 'Contents/MacOS/gmgn radio').write_bytes(Path('/bin/echo').read_bytes())
            (duplicate / 'Contents/MacOS/gmgn radio').chmod(0o755)
            # Spotlight 索引一个 bundle 就会把它注册进 LaunchServices（2026-10-02 实测）。
            subprocess.run(['mdimport', '-i', str(probe)], capture_output=True, timeout=120)
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if duplicate in module.registered_paths(canonical, lsregister):
                    break
                time.sleep(1)
            else:
                self.skipTest('这台机器上注入的 bundle 没有被 Spotlight 索引/注册，抓不到')

            ok, others = module.audit_single_registration(canonical, lsregister)
            self.assertFalse(ok, '注入了一份同 id 的副本，判据却报干净')
            self.assertIn(duplicate, others)

            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(dedupe.main(['--check']), 1)
            self.assertIn('FAIL: 注册表里', stderr.getvalue())
            self.assertIn(str(duplicate), stderr.getvalue())

            # 干净地收拾：文件还在时 `-u` 能注销（不会留下死注册），然后再删目录。
            module.ensure_single_registration(canonical, extra_paths=[duplicate],
                                              lsregister=lsregister)
            self.assertNotIn(duplicate, module.registered_paths(canonical, lsregister))
        finally:
            shutil.rmtree(probe, ignore_errors=True)
        module.ensure_single_registration(canonical, lsregister=lsregister)
        ok, others = module.audit_single_registration(canonical, lsregister)
        self.assertTrue(ok, f'注入测试没有把机器收拾干净：{others}')


def tree_digest(root, ignore=frozenset()):
    """目录内容的可比较指纹（相对路径 + 每个文件的字节），用于断言"字节一个没动"。"""
    digest = {}
    for path in sorted(Path(root).rglob('*')):
        if path.is_file() and path.name not in ignore:
            digest[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return digest


if __name__ == '__main__':
    unittest.main()
