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
import unittest

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
        for code in ['unknown_method', 'invalid_memory_status', 'wrong_peer']:
            child = Child()
            if code == 'wrong_peer':
                child.pid += 1
            path = str(Path(self.temp.name) / 'probe.sock')
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(path)
                server.listen(1)
                def serve():
                    connection, _ = server.accept()
                    with connection:
                        request = json.loads(connection.recv(4096))
                        self.assertEqual(request['method'], 'memory_status')
                        self.assertEqual(request['params'], {})
                        reply_code = 'invalid_memory_status' if code == 'wrong_peer' else code
                        connection.sendall(json.dumps({'id': request['id'], 'error': {'code': reply_code}}).encode() + b'\n')
                thread = threading.Thread(target=serve)
                thread.start()
                try:
                    if code in ['unknown_method', 'wrong_peer']:
                        expected = 'unknown_method' if code == 'unknown_method' else 'different process'
                        with self.assertRaisesRegex(RuntimeError, expected):
                            module.Runtime().verify(child, path, 1)
                    else:
                        module.Runtime().verify(child, path, 1)
                finally:
                    thread.join(timeout=2)
            Path(path).unlink()

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


if __name__ == '__main__':
    unittest.main()
