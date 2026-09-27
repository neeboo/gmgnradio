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


class FixtureRuntime(module.Runtime if module else object):
    """A runtime whose daemon row appears only after start, like an install.

    The process table (argv) and the real executable identity are injected
    separately so tests can model a same-UID impostor: an argv identical to the
    installed daemon while the actual executable image is something else. The
    fixture never calls the real libproc query, keeping tests hermetic.
    """

    def __init__(self, child_pid, row_pid=None, verify=True, executable_path=None,
                 executable_error=None):
        self.child = DaemonChild(child_pid)
        self.row_pid = child_pid if row_pid is None else row_pid
        self.command = None
        self.started = False
        self.events = []
        self.verify_for_real = verify
        self.executable = executable_path
        self.executable_error = executable_error
        self.executable_queries = []

    def processes(self):
        return [(self.row_pid, self.command)] if self.started else []

    def start(self, helper, root, sock):
        self.started = True
        if self.executable is None and self.executable_error is None:
            # The started daemon really runs the installed helper.
            self.executable = str(Path(helper).resolve())
        self.command = f'{helper} --root {root} --socket {sock} --concurrency 2'
        return self.child

    def verify(self, child, sock, timeout):
        self.events.append('verify')
        if self.verify_for_real:
            super().verify(child, sock, timeout)

    def executable_path(self, pid):
        self.executable_queries.append(pid)
        if self.executable_error is not None:
            raise self.executable_error
        return self.executable

    def stop_child(self, child, timeout):
        self.events.append('stop_child')


class InjectedArgumentRuntime(FixtureRuntime):
    """A runtime whose started daemon advertises injected extra arguments."""

    def __init__(self, child_pid, executable_path=None, executable_error=None):
        super().__init__(child_pid, verify=False, executable_path=executable_path,
                         executable_error=executable_error)

    def start(self, helper, root, sock):
        self.started = True
        legacy = Path(root).parent / 'PropGeneration'
        self.command = (f'{helper} --root {root} --socket {sock} --concurrency 2 '
                        f'--legacy-root {legacy} --socket /tmp/gmgn-injected.sock')
        return self.child


class StaticRuntime:
    """A runtime whose process table never changes (configure-memory-only).

    As with ``FixtureRuntime`` the injected executable identity stands in for
    the real libproc query so the test never inspects its own Python image.
    """

    def __init__(self, rows, executable_path=None, executable_error=None):
        self.rows = rows
        self.executable = executable_path
        self.executable_error = executable_error

    def processes(self):
        return list(self.rows)

    def executable_path(self, pid):
        if self.executable_error is not None:
            raise self.executable_error
        return self.executable


class MemorySocketFixture:
    """A Unix socket fixture that speaks the frozen memory_* wire protocol."""

    def __init__(self, path, reply=None):
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.raw = []
        self.requests = []
        self._reply_fn = reply
        self._closed = False
        self._connections = []
        self._server = socket.socket(socket.AF_UNIX)
        self._server.bind(self.path)
        self._server.listen(8)
        self._server.settimeout(0.2)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def open_connections(self):
        return len(self._connections)

    def _serve(self):
        while not self._closed:
            try:
                connection, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self._connections.append(connection)
            try:
                # Every accepted connection is context-managed and closed here,
                # so a fixture teardown can never leak a socket handle.
                with connection:
                    self._handle(connection)
            finally:
                try:
                    self._connections.remove(connection)
                except ValueError:
                    pass

    def _handle(self, connection):
        connection.settimeout(2)
        buffer = b''
        try:
            while True:
                try:
                    chunk = connection.recv(65536)
                except socket.timeout:
                    return
                if not chunk:
                    return
                self.raw.append(chunk)
                buffer += chunk
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    if not line.strip():
                        continue
                    request = json.loads(line)
                    self.requests.append(request)
                    reply = self._reply_fn(request) if self._reply_fn else self._default_reply(request)
                    if reply is not None:
                        connection.sendall(reply)
        except (OSError, ValueError):
            return

    def _default_reply(self, request):
        request_id = request.get('id')
        method = request.get('method')
        if method == 'memory_status' and request.get('params') == {}:
            code = 'invalid_memory_status'
            return json.dumps({'id': request_id, 'error': {'code': code, 'message': code}}).encode() + b'\n'
        if method == 'memory_configure':
            return json.dumps({'id': request_id, 'result': {'configured': True}}).encode() + b'\n'
        if method == 'memory_status':
            return json.dumps({'id': request_id, 'result': {
                'configured': {'compaction': True, 'embedding': True},
                'memory': None,
                'pendingTurns': 0,
                'orchestration': {'state': 'idle', 'lastError': None},
            }}).encode() + b'\n'
        code = 'unknown_method'
        return json.dumps({'id': request_id, 'error': {'code': code, 'message': code}}).encode() + b'\n'

    def close(self):
        self._closed = True
        for connection in list(self._connections):
            # Unblock a handler stuck in recv before joining the server thread.
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                connection.close()
            except OSError:
                pass
        try:
            self._server.close()
        except OSError:
            pass
        self._thread.join(timeout=3)
        for connection in list(self._connections):
            try:
                connection.close()
            except OSError:
                pass


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

    def run_install(self, env=None):
        return module.install(self.source, self.dest, self.root, runtime=self.runtime,
                              env={} if env is None else env)

    def test_missing_helper_never_stops(self):
        (self.source / 'Contents/Helpers/gmgn-taskd').unlink()
        with self.assertRaisesRegex(RuntimeError, 'helper'):
            self.run_install()
        self.assertEqual(self.runtime.events, [])

    def test_same_bundle_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'separate'):
            module.install(self.source, self.source, self.root, runtime=self.runtime, env={})
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
        fixed = 'New daemon memory interface verification failed'
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

    # -- explicit memory provider configuration ---------------------------

    def memory_env(self, **overrides):
        env = {
            'GMGN_MEMORY_COMPACTION_ENDPOINT': 'https://compaction.example',
            'GMGN_MEMORY_COMPACTION_TOKEN': 'compaction-fixture-token',
            'GMGN_MEMORY_COMPACTION_MODEL': 'compaction-fixture-model',
            'GMGN_MEMORY_EMBEDDING_ENDPOINT': 'http://127.0.0.1:9',
            'GMGN_MEMORY_EMBEDDING_TOKEN': 'embedding-fixture-token',
        }
        env.update(overrides)
        return env

    def command_for(self, helper=None, sock=None):
        helper = helper or self.dest / 'Contents/Helpers/gmgn-taskd'
        sock = sock or self.root / 'taskd.sock'
        return f'{helper} --root {self.root} --socket {sock} --concurrency 2'

    def static_runtime(self, rows):
        """A static runtime whose peer really is the installed helper image."""
        helper = self.dest / 'Contents/Helpers/gmgn-taskd'
        return StaticRuntime(rows, executable_path=str(helper.resolve()))

    def test_default_install_reports_missing_memory_variables(self):
        receipt = self.run_install()
        self.assertFalse(receipt['memory_configured'])
        self.assertEqual(receipt['missing_memory_variables'], [
            'GMGN_MEMORY_COMPACTION_ENDPOINT',
            'GMGN_MEMORY_COMPACTION_TOKEN',
            'GMGN_MEMORY_EMBEDDING_ENDPOINT',
            'GMGN_MEMORY_EMBEDDING_TOKEN',
        ])
        self.assertFalse(receipt['model_quality_verified'])
        self.assertEqual([e[0] for e in self.runtime.events], ['start', 'verify'])

    def test_partial_memory_configuration_fails_before_any_write(self):
        cases = [
            {'GMGN_MEMORY_COMPACTION_ENDPOINT': 'https://compaction.example'},
            {'GMGN_MEMORY_COMPACTION_ENDPOINT': 'https://compaction.example',
             'GMGN_MEMORY_COMPACTION_TOKEN': 'partial-token'},
            {'GMGN_MEMORY_EMBEDDING_TOKEN': 'partial-token'},
            {'GMGN_MEMORY_COMPACTION_MODEL': 'partial-model'},
        ]
        for env in cases:
            with self.subTest(env=env):
                with self.assertRaisesRegex(RuntimeError, 'incomplete'):
                    self.run_install(env=env)
                self.assertEqual(self.runtime.events, [])
                self.assertEqual((self.dest / 'Contents/Helpers/gmgn-taskd').read_text(), 'old')

    def test_configure_memory_only_requires_complete_configuration(self):
        for env in [{},
                    {'GMGN_MEMORY_EMBEDDING_ENDPOINT': 'http://127.0.0.1:9'}]:
            with self.subTest(env=env):
                with self.assertRaisesRegex(RuntimeError, 'incomplete'):
                    module.configure_memory_only(self.dest, self.root,
                                                 runtime=StaticRuntime([]), env=env, timeout=.2)

    def test_full_configuration_configures_two_providers_and_reads_status(self):
        fixture = MemorySocketFixture(self.root / 'taskd.sock')
        self.addCleanup(fixture.close)
        runtime = FixtureRuntime(os.getpid(), verify=True)
        receipt = module.install(self.source, self.dest, self.root, runtime=runtime,
                                 env=self.memory_env())
        self.assertTrue(receipt['memory_configured'])
        self.assertEqual(receipt['missing_memory_variables'], [])
        self.assertFalse(receipt['model_quality_verified'])
        configures = [r for r in fixture.requests if r['method'] == 'memory_configure']
        self.assertEqual([r['params']['kind'] for r in configures], ['compaction', 'embedding'])
        self.assertEqual(configures[0]['params']['endpoint'], 'https://compaction.example')
        self.assertEqual(configures[0]['params']['token'], 'compaction-fixture-token')
        self.assertEqual(configures[0]['params']['model'], 'compaction-fixture-model')
        self.assertEqual(configures[1]['params']['endpoint'], 'http://127.0.0.1:9')
        self.assertEqual(configures[1]['params']['token'], 'embedding-fixture-token')
        self.assertNotIn('model', configures[1]['params'])
        statuses = [r for r in fixture.requests
                    if r['method'] == 'memory_status' and r['params'] != {}]
        self.assertEqual(len(statuses), 1)
        self.assertEqual(statuses[0]['params'], {'scope': module.MEMORY_STATUS_SCOPE})

    def test_configure_memory_only_uses_installed_daemon_and_reads_back(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        self.addCleanup(fixture.close)
        runtime = self.static_runtime([(os.getpid(), self.command_for(sock=sock))])
        receipt = module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                               env=self.memory_env())
        self.assertTrue(receipt['memory_configured'])
        self.assertTrue(receipt['daemon_verified'])
        self.assertFalse(receipt['model_quality_verified'])
        self.assertEqual(receipt['missing_memory_variables'], [])
        kinds = [r['params']['kind'] for r in fixture.requests if r['method'] == 'memory_configure']
        self.assertEqual(kinds, ['compaction', 'embedding'])
        statuses = [r for r in fixture.requests if r['method'] == 'memory_status']
        self.assertEqual(len(statuses), 1)
        self.assertEqual(statuses[0]['params'], {'scope': module.MEMORY_STATUS_SCOPE})

    def test_wrong_peer_never_receives_credentials(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = StaticRuntime([(os.getpid() + 12345, self.command_for(sock=sock))])
        try:
            with self.assertRaisesRegex(RuntimeError, 'peer'):
                module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                             env=self.memory_env(), timeout=.5)
        finally:
            fixture.close()
        self.assertEqual(fixture.raw, [])
        self.assertEqual([r for r in fixture.requests if r['method'] == 'memory_configure'], [])

    def test_install_rejects_token_when_child_pid_differs_from_socket(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = FixtureRuntime(os.getpid() + 12345, row_pid=os.getpid(), verify=False)
        try:
            with self.assertRaisesRegex(RuntimeError, 'peer'):
                module.install(self.source, self.dest, self.root, runtime=runtime,
                               env=self.memory_env())
        finally:
            fixture.close()
        # The established child-pid check fails before the exe query is made.
        self.assertEqual(runtime.executable_queries, [])
        self.assertEqual(fixture.raw, [])
        self.assertEqual([r for r in fixture.requests if r['method'] == 'memory_configure'], [])

    def injected_command(self, sock):
        """A daemon command that shares the valid prefix but injects arguments."""
        legacy = self.root.parent / 'PropGeneration'
        return (f'{self.dest}/Contents/Helpers/gmgn-taskd --root {self.root} '
                f'--socket {sock} --concurrency 2 --legacy-root {legacy} '
                f'--socket /tmp/gmgn-injected.sock')

    def test_daemon_command_matching_is_exact_no_extra_arguments(self):
        helper = self.dest / 'Contents/Helpers/gmgn-taskd'
        sock = self.root / 'taskd.sock'
        base = f'{helper} --root {self.root} --socket {sock}'
        legacy = self.root.parent / 'PropGeneration'
        valid = [
            base,
            base + ' --concurrency 2',
            base + f' --concurrency 2 --legacy-root {legacy}',
        ]
        attacks = [
            base + ' --concurrency 3',
            base + ' --concurrency 2 --legacy-root /tmp/elsewhere',
            base + ' --concurrency 2 --root /tmp/attacker',
            base + ' --concurrency 2 --socket /tmp/attacker.sock',
            base + f' --concurrency 2 --legacy-root {legacy} --socket /tmp/attacker.sock',
            base + f' --concurrency 2 --legacy-root {legacy} --root /tmp/attacker',
            base + ' --extra',
            f'{helper} --root {self.root} --socket {sock}-extra',
        ]
        rows = list(enumerate(valid + attacks, start=1))
        self.assertEqual(module._matching_daemon_pids(rows, helper, self.root, sock), [1, 2, 3])

    def test_configure_memory_only_rejects_injected_daemon_arguments(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = StaticRuntime([(os.getpid(), self.injected_command(sock))])
        try:
            with self.assertRaisesRegex(RuntimeError, 'peer'):
                module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                             env=self.memory_env(), timeout=.5)
        finally:
            fixture.close()
        self.assertEqual(fixture.raw, [])
        self.assertEqual([r for r in fixture.requests if r['method'] == 'memory_configure'], [])

    def test_install_rejects_injected_daemon_arguments(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = InjectedArgumentRuntime(os.getpid())
        try:
            with self.assertRaisesRegex(RuntimeError, 'peer'):
                module.install(self.source, self.dest, self.root, runtime=runtime,
                               env=self.memory_env())
        finally:
            fixture.close()
        self.assertEqual(fixture.raw, [])
        self.assertEqual([r for r in fixture.requests if r['method'] == 'memory_configure'], [])

    # -- real executable identity: argv alone is forgeable ------------------

    def attacker_executable(self):
        """A different real executable image that shares the daemon argv."""
        return self.source / 'Contents/Helpers/gmgn-taskd'

    def test_configure_memory_only_rejects_same_argv_different_executable(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = StaticRuntime(
            [(os.getpid(), self.command_for(sock=sock))],
            executable_path=str(self.attacker_executable().resolve()))
        try:
            with self.assertRaises(RuntimeError) as raised:
                module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                             env=self.memory_env(), timeout=.5)
        finally:
            fixture.close()
        self.assertEqual(str(raised.exception), module.MEMORY_EXECUTABLE_UNVERIFIED)
        self.assertIsNone(raised.exception.__cause__)
        self.assertEqual(fixture.raw, [])
        self.assertEqual([r for r in fixture.requests if r['method'] == 'memory_configure'], [])

    def test_configure_memory_only_fails_closed_when_executable_query_fails(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = StaticRuntime(
            [(os.getpid(), self.command_for(sock=sock))],
            executable_error=OSError('libproc-fixture-secret'))
        try:
            with self.assertRaises(RuntimeError) as raised:
                module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                             env=self.memory_env(), timeout=.5)
        finally:
            fixture.close()
        self.assertEqual(str(raised.exception), module.MEMORY_EXECUTABLE_UNVERIFIED)
        self.assertIsNone(raised.exception.__cause__)
        self.assertNotIn('libproc-fixture-secret', str(raised.exception))
        self.assertEqual(fixture.raw, [])
        self.assertEqual([r for r in fixture.requests if r['method'] == 'memory_configure'], [])

    def test_install_rejects_same_argv_different_executable(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = FixtureRuntime(
            os.getpid(), verify=False,
            executable_path=str(self.attacker_executable().resolve()))
        try:
            with self.assertRaisesRegex(RuntimeError, 'executable'):
                module.install(self.source, self.dest, self.root, runtime=runtime,
                               env=self.memory_env())
        finally:
            fixture.close()
        self.assertEqual(fixture.raw, [])
        self.assertEqual([r for r in fixture.requests if r['method'] == 'memory_configure'], [])

    def test_install_fails_closed_when_executable_query_fails(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = FixtureRuntime(os.getpid(), verify=False,
                                 executable_error=OSError('libproc-fixture-secret'))
        try:
            with self.assertRaisesRegex(RuntimeError, 'executable') as raised:
                module.install(self.source, self.dest, self.root, runtime=runtime,
                               env=self.memory_env())
        finally:
            fixture.close()
        self.assertNotIn('libproc-fixture-secret', str(raised.exception))
        self.assertEqual(fixture.raw, [])
        self.assertEqual([r for r in fixture.requests if r['method'] == 'memory_configure'], [])

    def test_executable_identity_is_checked_only_after_process_identity(self):
        """A forged argv fails the cheap process checks before any exe query."""
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        runtime = InjectedArgumentRuntime(os.getpid(),
                                          executable_error=OSError('must-not-be-reached'))
        try:
            with self.assertRaisesRegex(RuntimeError, 'peer') as raised:
                module.install(self.source, self.dest, self.root, runtime=runtime,
                               env=self.memory_env())
        finally:
            fixture.close()
        self.assertEqual(runtime.executable_queries, [])
        self.assertNotIn('must-not-be-reached', str(raised.exception))
        self.assertEqual(fixture.raw, [])

    def test_memory_socket_fixture_closes_accepted_connections(self):
        sock = self.root / 'taskd.sock'
        fixture = MemorySocketFixture(sock)
        client = socket.socket(socket.AF_UNIX)
        try:
            client.connect(str(sock))
            deadline = time.monotonic() + 2
            while fixture.open_connections == 0 and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertEqual(fixture.open_connections, 1)
            fixture.close()
            self.assertEqual(fixture.open_connections, 0)
        finally:
            client.close()
            fixture.close()

    def test_malformed_and_error_replies_are_sanitized(self):
        sock = self.root / 'taskd.sock'
        env = self.memory_env()
        runtime = self.static_runtime([(os.getpid(), self.command_for(sock=sock))])
        cases = {
            'malformed': lambda request: b'not-a-json-frame\n',
            'error': lambda request: json.dumps({'id': request.get('id'), 'error': {
                'code': 'invalid_token',
                'message': 'invalid_token:fixture-secret-invalid_token'}}).encode() + b'\n',
        }
        for name, reply in cases.items():
            with self.subTest(case=name):
                if sock.exists():
                    sock.unlink()
                fixture = MemorySocketFixture(sock, reply=reply)
                try:
                    with self.assertRaises(RuntimeError) as raised:
                        module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                                     env=env, timeout=.5)
                finally:
                    fixture.close()
                message = str(raised.exception)
                for secret in ['compaction-fixture-token', 'embedding-fixture-token',
                               'https://compaction.example', 'http://127.0.0.1:9',
                               'fixture-secret', 'invalid_token']:
                    self.assertNotIn(secret, message)
        if sock.exists():
            sock.unlink()

    def test_malformed_service_reply_shapes_are_fixed_runtime_errors(self):
        sock = self.root / 'taskd.sock'
        env = self.memory_env()
        runtime = self.static_runtime([(os.getpid(), self.command_for(sock=sock))])

        def frame(request_id, **fields):
            body = {'id': request_id}
            body.update(fields)
            return json.dumps(body).encode() + b'\n'

        def status_ok(request):
            return frame(request['id'], result={
                'configured': {'compaction': True, 'embedding': True}})

        def reply_configure(payload):
            def reply(request):
                if request['method'] == 'memory_configure':
                    return frame(request['id'], **payload)
                return status_ok(request)
            return reply

        def reply_status(payload):
            def reply(request):
                if request['method'] == 'memory_configure':
                    return frame(request['id'], result={'configured': True})
                return frame(request['id'], **payload)
            return reply

        shapes = {
            'top_level_array': lambda request: b'[]\n',
            'top_level_null': lambda request: b'null\n',
            'top_level_string': lambda request: b'"service-secret"\n',
            'top_level_number': lambda request: b'17\n',
            'configure_result_array': reply_configure({'result': []}),
            'configure_result_string': reply_configure({'result': 'service-secret'}),
            'configure_result_null': reply_configure({'result': None}),
            'configure_result_number': reply_configure({'result': 7}),
            'configure_configured_array': reply_configure({'result': {'configured': ['service-secret']}}),
            'configure_configured_string': reply_configure({'result': {'configured': 'service-secret'}}),
            'configure_configured_null': reply_configure({'result': {'configured': None}}),
            'configure_error_string': reply_configure({'error': 'service-secret'}),
            'configure_error_nested': reply_configure({'error': {'code': {'nested': ['service-secret']}}}),
            'configure_wrong_id': lambda request: frame('not-the-request-id', result={'configured': True}),
            'status_result_string': reply_status({'result': 'service-secret'}),
            'status_configured_array': reply_status({'result': {'configured': ['service-secret']}}),
            'status_configured_number': reply_status({'result': {'configured': 1}}),
            'status_error_nested': reply_status({'error': {'code': ['service-secret']}}),
        }
        for name, reply in shapes.items():
            with self.subTest(shape=name):
                if sock.exists():
                    sock.unlink()
                fixture = MemorySocketFixture(sock, reply=reply)
                try:
                    with self.assertRaises(RuntimeError) as raised:
                        module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                                     env=env, timeout=.5)
                finally:
                    fixture.close()
                exception = raised.exception
                self.assertIs(type(exception), RuntimeError)
                self.assertIsNone(exception.__cause__)
                self.assertNotIn('service-secret', str(exception))
                self.assertNotIn('not-the-request-id', str(exception))
        if sock.exists():
            sock.unlink()

    def test_memory_socket_timeout_is_sanitized(self):
        sock = self.root / 'taskd.sock'
        if sock.exists():
            sock.unlink()
        fixture = MemorySocketFixture(sock, reply=lambda request: None)
        self.addCleanup(fixture.close)
        runtime = self.static_runtime([(os.getpid(), self.command_for(sock=sock))])
        with self.assertRaises(RuntimeError) as raised:
            module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                         env=self.memory_env(), timeout=.3)
        message = str(raised.exception)
        self.assertIn('timed out', message)
        self.assertIsNone(raised.exception.__cause__)
        self.assertTrue(raised.exception.__suppress_context__)
        for secret in ['compaction-fixture-token', 'embedding-fixture-token',
                       'https://compaction.example', 'http://127.0.0.1:9']:
            self.assertNotIn(secret, message)

    def test_memory_socket_unavailable_is_sanitized_from_none(self):
        sock = Path(self.temp.name) / 'missing.sock'
        runtime = StaticRuntime([(os.getpid(), self.command_for(sock=sock))])
        with self.assertRaises(RuntimeError) as raised:
            module.configure_memory_only(self.dest, self.root, runtime=runtime,
                                         env=self.memory_env(), timeout=.3)
        self.assertIn('unavailable', str(raised.exception))
        self.assertIsNone(raised.exception.__cause__)
        self.assertTrue(raised.exception.__suppress_context__)


if __name__ == '__main__':
    unittest.main()
