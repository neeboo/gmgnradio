#!/usr/bin/env python3
"""Production client/consumer over private taskd HTTP; no provider/UI/audio."""
import argparse
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--daemon', type=Path)
    args=parser.parse_args()
    if args.run and (args.daemon is None or not args.daemon.is_absolute()): parser.error('explicit absolute --daemon required')
    repo=Path(__file__).resolve().parents[1]
    source=repo/'apps/macos/Sources/GMGNRadio/Presence'
    with tempfile.TemporaryDirectory(prefix='gmgn-generation-authority-') as directory:
        parent=Path(directory).resolve(); binary=parent/'consumer'; children=[]
        subprocess.run(['swiftc','-j1','-swift-version','6','-parse-as-library',
            str(source/'TaskdHTTPTransport.swift'),str(repo/'tools/fixtures/PrivateAttachmentAuthority.swift'),
            str(source/'PropGenerationClient.swift'),str(source/'PropGenerationConfiguration.swift'),
            str(source/'RustGenerationConfigurationClient.swift'),
            str(repo/'apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift'),
            str(repo/'tools/test-rust-generation-configuration-client.swift'),'-o',str(binary)],check=True)
        if not args.run:
            print('PASS actual generation authority client/Unity consumer compile; runtime not run'); return
        with (parent/'daemon.log').open('w') as log:
            def start(root):
                endpoint=root/'taskd.endpoint.json'; endpoint.unlink(missing_ok=True)
                child=subprocess.Popen([str(args.daemon),'--root',str(root),'--endpoint-file',str(endpoint),'--concurrency','1'],stdout=log,stderr=log,start_new_session=True)
                children.append(child); print(f'PRIVATE PID/PGID={child.pid}',flush=True)
                for _ in range(1000):
                    assert child.poll() is None
                    if endpoint.exists(): return child,endpoint
                    time.sleep(.02)
                raise AssertionError('private daemon readiness')
            def stop(child):
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try: child.wait(timeout=5)
                    except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=5)
                for check in (lambda:os.kill(child.pid,0),lambda:os.killpg(child.pid,0)):
                    try: check();raise AssertionError('private child survived')
                    except ProcessLookupError: pass
                print(f'REAPED PID/PGID={child.pid} exit={child.returncode}',flush=True)
            try:
                for mode in ('seed','corrupt'):
                    case=parent/mode;case.mkdir(mode=0o700); root=case/'TaskService';root.mkdir(mode=0o700)
                    child,endpoint=start(root)
                    subprocess.run([str(binary),str(endpoint),str(root),mode],check=True)
                    with sqlite3.connect(root/'tasks.sqlite3') as db:
                        state=db.execute('SELECT revision,endpoint,secret_ref,imported FROM generation_configuration').fetchone()
                        requests=db.execute('SELECT request,digest,response FROM generation_configuration_requests').fetchall()
                        assert state[3]==1 and state[1]=='http://127.0.0.1:8192'
                        assert all('synthetic-' not in str(row) for row in requests)
                    stop(child);child,endpoint=start(root)
                    subprocess.run([str(binary),str(endpoint),str(root),'reopen'],check=True)
                    with sqlite3.connect(root/'tasks.sqlite3') as db:
                        assert db.execute('SELECT revision,endpoint,secret_ref,imported FROM generation_configuration').fetchone()==state
                        assert db.execute('SELECT count(*) FROM generation_configuration_requests').fetchone()[0]==len(requests)
                    stop(child)
                    print(f'PASS {mode} SQLite metadata/private-secret/restart',flush=True)
            finally:
                for child in children:
                    if child.poll() is None: stop(child)
        print('PASS all owned children reaped; private root removed on exit')
if __name__=='__main__': main()
