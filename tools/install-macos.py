#!/usr/bin/env python3
"""Install one macOS bundle and replace its scoped task daemon together."""
import argparse
import ctypes
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


MEMORY_PROVIDER_VARIABLES = {
    'compaction': ('GMGN_MEMORY_COMPACTION_ENDPOINT',
                   'GMGN_MEMORY_COMPACTION_TOKEN',
                   'GMGN_MEMORY_COMPACTION_MODEL'),
    'embedding': ('GMGN_MEMORY_EMBEDDING_ENDPOINT',
                  'GMGN_MEMORY_EMBEDDING_TOKEN',
                  'GMGN_MEMORY_EMBEDDING_MODEL'),
}
MEMORY_STATUS_SCOPE = {'worldID': 'install', 'residentScope': 'install'}
# Fixed, safe failure strings: tokens, endpoints and raw service errors must
# never reach a log, an exception or a receipt.
MEMORY_INCOMPLETE = 'Memory provider configuration is incomplete'
MEMORY_PEER_UNVERIFIED = 'Installed daemon socket peer verification failed'
MEMORY_EXECUTABLE_UNVERIFIED = 'Installed daemon executable verification failed'
MEMORY_UNAVAILABLE = 'Installed daemon memory socket is unavailable'
MEMORY_CONFIGURE_FAILED = 'Installed daemon rejected the memory configuration'
MEMORY_STATUS_FAILED = 'Installed daemon memory status verification failed'
MEMORY_TIMEOUT = 'Installed daemon memory socket timed out'
MEMORY_VERIFY_FAILED = 'New daemon memory interface verification failed'
# libproc.h: proc_pidpath returns the bytes written (<= 0 on failure) and
# PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN. Both are fixed constants so the
# query can never be steered by attacker input.
LIBPROC_PATH = '/usr/lib/libproc.dylib'
PROC_PIDPATHINFO_MAXSIZE = 4096


def _trimmed(value):
    if value is None:
        return None
    trimmed = value.strip()
    return trimmed or None


def read_memory_configuration(env=None):
    """Parse the two explicit memory provider configurations.

    Returns ``(providers, missing_required_variables, any_variable_set)``.
    ``endpoint``/``token`` must both be present for a provider to count;
    ``model`` is optional and only read when the pair is complete.
    """
    env = os.environ if env is None else env
    providers = {}
    missing = []
    any_set = False
    for kind, (endpoint_var, token_var, model_var) in MEMORY_PROVIDER_VARIABLES.items():
        endpoint = _trimmed(env.get(endpoint_var))
        token = _trimmed(env.get(token_var))
        model = _trimmed(env.get(model_var))
        if endpoint is None:
            missing.append(endpoint_var)
        if token is None:
            missing.append(token_var)
        if endpoint is not None or token is not None or model is not None:
            any_set = True
        if endpoint is not None and token is not None:
            providers[kind] = {'endpoint': endpoint, 'token': token, 'model': model}
    return providers, missing, any_set


def require_complete_memory_configuration(env=None):
    """Reject a partial configuration before any install side effect.

    No required variable set is a valid "memory off" install; a partial set is
    an operator error that must fail before any process is stopped or bundle is
    replaced.
    """
    providers, missing, any_set = read_memory_configuration(env)
    complete = len(providers) == len(MEMORY_PROVIDER_VARIABLES)
    if any_set and not complete:
        raise RuntimeError(MEMORY_INCOMPLETE)
    return providers, missing, complete


def _daemon_command_tails(root, sock):
    """The three exact daemon invocations this installer owns.

    Both process replacement and socket peer verification accept these command
    lines and nothing else. A command that merely shares this prefix but adds
    any argument (including a duplicate --root/--socket) is a different,
    untrusted process and must never receive a credential.
    """
    base = f' --root {root} --socket {sock}'
    return (base,
            base + ' --concurrency 2',
            base + f' --concurrency 2 --legacy-root {root.parent / "PropGeneration"}')


def _daemon_commands(helper, root, sock):
    return {f'{helper}{tail}' for tail in _daemon_command_tails(root, sock)}


def _matching_daemon_pids(rows, helper, root, sock):
    commands = _daemon_commands(helper, root, sock)
    return [pid for pid, command in rows if command in commands]


def _mapping(value):
    """Return ``value`` only when it is a JSON object, otherwise an empty one."""
    return value if isinstance(value, dict) else {}


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


def _exchange(connection, stream, request_id, method, params, failure):
    payload = json.dumps({'id': request_id, 'method': method, 'params': params})
    connection.sendall(payload.encode() + b'\n')
    line = stream.readline(65536)
    if not line:
        raise RuntimeError(failure)
    try:
        response = json.loads(line)
    except ValueError:
        raise RuntimeError(failure) from None
    if not isinstance(response, dict) or response.get('id') != request_id:
        raise RuntimeError(failure)
    return response


def _darwin_executable_path(pid):
    """Resolve ``pid``'s real executable image via libproc.

    ``proc_pidpath`` asks the kernel for the executable that was actually
    exec'd, not the forgeable ``argv`` that ``ps`` reports. The query uses one
    fixed buffer and rejects a non-positive result, and the returned path is
    resolved before comparison. Any failure returns ``None`` so callers fail
    closed without leaking a lower-level exception.
    """
    libproc = ctypes.CDLL(LIBPROC_PATH)
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    libproc.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    written = libproc.proc_pidpath(pid, buffer, PROC_PIDPATHINFO_MAXSIZE)
    if written <= 0:
        return None
    raw = buffer.value
    if not raw:
        return None
    return str(Path(raw.decode('utf-8', 'surrogateescape')).resolve())


def _executable_identity_verified(runtime, pid, helper):
    """Whether ``pid`` really runs the installed helper executable.

    The command line alone cannot prove this: a same-UID impostor can set an
    identical ``argv``. Only the kernel's executable image decides, and any
    query failure is treated as unverified.
    """
    try:
        actual = runtime.executable_path(pid)
    except Exception:
        return False
    if not isinstance(actual, str) or not actual:
        return False
    try:
        return Path(actual).resolve() == Path(helper).resolve()
    except (OSError, ValueError):
        return False


def configure_daemon_memory(helper, root, sock, providers, runtime, timeout=15,
                            expected_pid=None):
    """Configure both memory providers over a peer-verified Unix socket.

    The listening peer's LOCAL_PEERPID must match the exact installed helper
    process for this root/socket (and, during a normal install, the child that
    was just started). The peer's real executable image must also be the
    installed helper, because the process-table argv is forgeable by a same-UID
    impostor. Only then is any token written.
    """
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(timeout)
            connection.connect(str(sock))
            # Darwin sys/un.h: SOL_LOCAL=0, LOCAL_PEERPID=0x002. Read before
            # any credential frame so the peer can be trusted first.
            peer_pid = connection.getsockopt(0, 0x002)
            matching = _matching_daemon_pids(runtime.processes(), helper, root, sock)
            if peer_pid not in matching:
                raise RuntimeError(MEMORY_PEER_UNVERIFIED)
            if expected_pid is not None and peer_pid != expected_pid:
                raise RuntimeError(MEMORY_PEER_UNVERIFIED)
            # The process table is argv, which a same-UID impostor can forge
            # exactly. Verify the peer's real executable image before any
            # credential frame is written.
            if not _executable_identity_verified(runtime, peer_pid, helper):
                raise RuntimeError(MEMORY_EXECUTABLE_UNVERIFIED) from None
            with connection.makefile('rb') as stream:
                for kind in ('compaction', 'embedding'):
                    provider = providers[kind]
                    params = {'kind': kind, 'endpoint': provider['endpoint'],
                              'token': provider['token']}
                    if provider['model'] is not None:
                        params['model'] = provider['model']
                    request_id = f'install-{kind}'
                    response = _exchange(connection, stream, request_id, 'memory_configure',
                                         params, MEMORY_CONFIGURE_FAILED)
                    result = _mapping(response.get('result'))
                    if response.get('error') is not None \
                            or result.get('configured') is not True:
                        raise RuntimeError(MEMORY_CONFIGURE_FAILED)
                response = _exchange(connection, stream, 'install-status', 'memory_status',
                                     {'scope': dict(MEMORY_STATUS_SCOPE)}, MEMORY_STATUS_FAILED)
                configured = _mapping(_mapping(response.get('result')).get('configured'))
                if response.get('error') is not None \
                        or configured.get('compaction') is not True \
                        or configured.get('embedding') is not True:
                    raise RuntimeError(MEMORY_STATUS_FAILED)
    except socket.timeout:
        raise RuntimeError(MEMORY_TIMEOUT) from None
    except OSError:
        raise RuntimeError(MEMORY_UNAVAILABLE) from None
    return True


class Runtime:
    def processes(self):
        output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True)
        return [(int(pid), command) for line in output.splitlines()
                for pid, command in [line.strip().split(None, 1)]]

    def executable_path(self, pid):
        """The resolved real executable path for ``pid``, or ``None``.

        Read-only: it neither signals nor mutates any process. It is also fail
        closed: a missing/renamed libproc, a failed query or an undecodable
        path all return ``None`` rather than leaking a lower-level exception.
        """
        try:
            return _darwin_executable_path(pid)
        except Exception:
            return None

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
                        raise RuntimeError(MEMORY_VERIFY_FAILED) from None
                    # A live child alone does not prove it owns this socket.
                    if peer_pid != child.pid:
                        raise RuntimeError('Daemon socket belongs to a different process')
                if not _valid_memory_probe_response(response):
                    raise RuntimeError(MEMORY_VERIFY_FAILED)
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


def install(source, destination, root, runtime=None, timeout=15, env=None):
    source, destination, root = (Path(p).expanduser().resolve() for p in (source, destination, root))
    providers, missing, memory_complete = require_complete_memory_configuration(env)
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
        commands = set()
        for app in (source, destination):
            commands.update(_daemon_commands(app / 'Contents/Helpers/gmgn-taskd', root, sock))
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
        if memory_complete:
            configure_daemon_memory(destination / 'Contents/Helpers/gmgn-taskd', root, sock,
                                    providers, runtime, timeout, expected_pid=child.pid)
        return {'destination': str(destination), 'backup': str(backup) if backup.exists() else None,
                'daemon_verified': True, 'app_stopped': bool(apps), 'open_app_manually': True,
                'memory_configured': memory_complete,
                'missing_memory_variables': missing,
                'model_quality_verified': False}
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


def configure_memory_only(destination, root, runtime=None, timeout=15, env=None):
    """Configure memory providers on the already-installed daemon.

    Never parses ``--source``, never starts or stops the app/daemon and never
    replaces the bundle: it only speaks the frozen memory protocol to the
    running installed daemon after verifying the socket peer.
    """
    destination, root = (Path(p).expanduser().resolve() for p in (destination, root))
    providers, _missing, complete = require_complete_memory_configuration(env)
    if not complete:
        raise RuntimeError(MEMORY_INCOMPLETE)
    validate(destination)
    runtime = runtime or Runtime()
    sock = root / 'taskd.sock'
    helper = destination / 'Contents/Helpers/gmgn-taskd'
    configure_daemon_memory(helper, root, sock, providers, runtime, timeout)
    return {'destination': str(destination), 'memory_configured': True,
            'daemon_verified': True, 'missing_memory_variables': [],
            'model_quality_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--destination', type=Path, default=Path('/Applications/gmgn radio.app'))
    parser.add_argument('--root', type=Path, default=Path.home() / 'Library/Application Support/gmgn radio/TaskService')
    parser.add_argument('--configure-memory-only', action='store_true',
                        help='Configure the installed daemon memory providers without installing.')
    args = parser.parse_args()
    try:
        if args.configure_memory_only:
            print(json.dumps(configure_memory_only(args.destination, args.root), ensure_ascii=False))
        else:
            if args.source is None:
                parser.error('--source is required unless --configure-memory-only is used')
            print(json.dumps(install(args.source, args.destination, args.root), ensure_ascii=False))
    except Exception as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
