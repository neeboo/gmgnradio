#!/usr/bin/env python3
import importlib.util
import os
import plistlib
from pathlib import Path
import tempfile
import json
import socket
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
            for relative in ['Contents/Helpers/gmgn-taskd', 'Contents/MacOS/gmgn radio']:
                p = app / relative
                p.write_text(marker)
                p.chmod(0o755)
        self.runtime = Runtime()

    def run_install(self):
        return module.install(self.source, self.dest, self.root, runtime=self.runtime)

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
        self.runtime.after_stop = [(2, f'{self.dest}/Contents/Helpers/gmgn-taskd --root {self.root} --socket {self.root}/taskd.sock --concurrency 2')]
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

    def test_probe_checks_actual_socket_response(self):
        class Child:
            pid = os.getpid()
            def poll(self):
                return None
        secret = 'fixture-secret'
        sensitive = 'https://memory.example/v1/status?token=fixture-secret&scope=install'
        fixed = module.DAEMON_VERIFY_FAILED
        cases = {
            # A well-formed reply with the expected error shape is the only
            # outcome that verifies the probe.
            'invalid_memory_status': (
                lambda rid: {'id': rid, 'error': {'code': 'invalid_memory_status'}}, None),
            # Any other reply shape is a fixed, sanitized failure that never
            # echoes the service payload.
            'unknown_method': (
                lambda rid: {'id': rid, 'error': {'code': 'unknown_method'}}, fixed),
            'error_array': (lambda rid: {'id': rid, 'error': []}, fixed),
            'error_null': (lambda rid: {'id': rid, 'error': None}, fixed),
            'response_array': (lambda rid: [], fixed),
            'response_null': (lambda rid: None, fixed),
            'malformed_frame': (lambda rid: b'not-a-json-frame\n', fixed),
            'unknown_method_with_secret': (
                lambda rid: {'id': rid, 'error': {
                    'code': 'unknown_method', 'message': f'{secret} {sensitive}'}}, fixed),
            'wrong_peer': (
                lambda rid: {'id': rid, 'error': {'code': 'invalid_memory_status'}},
                'different process'),
        }
        for name, (reply, expected) in cases.items():
            with self.subTest(case=name):
                child = Child()
                if name == 'wrong_peer':
                    child.pid += 1
                path = str(Path(self.temp.name) / 'probe.sock')
                try:
                    with socket.socket(socket.AF_UNIX) as server:
                        server.bind(path)
                        server.listen(1)
                        def serve():
                            connection, _ = server.accept()
                            with connection:
                                request = json.loads(connection.recv(4096))
                                self.assertEqual(request['method'], 'memory_status')
                                self.assertEqual(request['params'], {})
                                payload = reply(request['id'])
                                if not isinstance(payload, bytes):
                                    payload = json.dumps(payload).encode() + b'\n'
                                connection.sendall(payload)
                        thread = threading.Thread(target=serve)
                        thread.start()
                        try:
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
                            thread.join(timeout=2)
                finally:
                    if os.path.exists(path):
                        os.unlink(path)

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
                             (2, f'{helper} --root {self.root} --socket {self.root}/taskd.sock --concurrency 2'),
                             (3, f'{helper} --root /other --socket /other/taskd.sock --concurrency 2')]
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
        return {key: value for key, value in receipt.items() if key != 'backup'}

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


if __name__ == '__main__':
    unittest.main()
