#!/usr/bin/env python3
"""Install one macOS bundle and replace its scoped task daemon together."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import subprocess
import tempfile
import time


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
                        response = json.loads(stream.readline(65536))
                    # A live child alone does not prove it owns this socket.
                    if peer_pid != child.pid:
                        raise RuntimeError('Daemon socket belongs to a different process')
                if response.get('id') != 'install-probe' or response.get('error', {}).get('code') != 'invalid_memory_status':
                    raise RuntimeError(f'New daemon memory interface verification failed: {response}')
                if child.poll() is not None:
                    raise RuntimeError('New daemon exited after verification')
                return
            except (OSError, ValueError):
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


def install(source, destination, root, runtime=None, timeout=15):
    source, destination, root = (Path(p).expanduser().resolve() for p in (source, destination, root))
    if source == destination or source in destination.parents or destination in source.parents:
        raise RuntimeError('Source and destination must be separate bundles')
    validate(source)
    if destination.exists():
        validate(destination, require_helper=False)
    runtime = runtime or Runtime()
    sock = root / 'taskd.sock'
    destination.parent.mkdir(parents=True, exist_ok=True)
    workspace = Path(tempfile.mkdtemp(prefix='.gmgn-install-', dir=destination.parent))
    staged, backup = workspace / 'staged.backup', workspace / 'previous.backup'
    child = None
    swapped = False
    try:
        shutil.copytree(source, staged, symlinks=True)
        validate(staged)
        rows = runtime.processes()
        executables = {str(app / 'Contents/MacOS/gmgn radio') for app in (source, destination)}
        apps = [(pid, command) for pid, command in rows if command in executables]
        for pid, command in apps:
            runtime.stop(pid, command, timeout)
        base = f' --root {root} --socket {sock}'
        tails = {base, base + ' --concurrency 2',
                 base + f' --concurrency 2 --legacy-root {root.parent / "PropGeneration"}'}
        commands = {str(app / 'Contents/Helpers/gmgn-taskd') + tail
                    for app in (source, destination) for tail in tails}
        daemons = [(pid, command) for pid, command in runtime.processes() if command in commands]
        for pid, command in daemons:
            runtime.stop(pid, command, timeout)
        if destination.exists():
            destination.rename(backup)
        try:
            staged.rename(destination)
        except Exception:
            if backup.exists():
                backup.rename(destination)
            raise
        swapped = True
        child = runtime.start(destination / 'Contents/Helpers/gmgn-taskd', root, sock)
        runtime.verify(child, sock, timeout)
        return {'destination': str(destination), 'backup': str(backup) if backup.exists() else None,
                'daemon_verified': True, 'app_stopped': bool(apps), 'open_app_manually': True}
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
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--destination', type=Path, default=Path('/Applications/gmgn radio.app'))
    parser.add_argument('--root', type=Path, default=Path.home() / 'Library/Application Support/gmgn radio/TaskService')
    args = parser.parse_args()
    try:
        print(json.dumps(install(args.source, args.destination, args.root), ensure_ascii=False))
    except Exception as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
