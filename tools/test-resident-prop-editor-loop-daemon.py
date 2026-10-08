#!/usr/bin/env python3
"""Actual resident loop + private scheduler/intent SQLite, no model or UI."""
import argparse
import http.client
import json
import os
import pathlib
import signal
import sqlite3
import subprocess
import tempfile
import time
import uuid

REPO=pathlib.Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--daemon',required=True,type=pathlib.Path)
    parser.add_argument('--log',type=pathlib.Path,default=pathlib.Path('/tmp')/('gmgn-rust-prop-editor-loop-'+str(uuid.uuid4())+'.log'))
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='gmgn-private-prop-editor-loop-') as temporary:
        root=pathlib.Path(temporary).resolve();root.chmod(0o700)
        endpoint=root/'taskd.endpoint.json'
        process=subprocess.Popen([str(args.daemon.resolve()),'--root',str(root),'--endpoint-file',str(endpoint),'--concurrency','1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        def stop():
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGTERM)
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=3)
            process.communicate(timeout=3)
            for check in (lambda:os.kill(process.pid,0),lambda:os.killpg(process.pid,0)):
                try:check()
                except ProcessLookupError:pass
                else:raise AssertionError('owned daemon PID/process group survived stop')
        def rpc(method,params):
            descriptor=json.loads(endpoint.read_text());host,port=descriptor['address'].split(':')
            assert host=='127.0.0.1'
            connection=http.client.HTTPConnection(host,int(port),timeout=10)
            connection.request('POST','/rpc',json.dumps({'id':'loop-fixture','method':method,'params':params}),{'Authorization':'Bearer '+descriptor['token'],'Content-Type':'application/json'})
            response=connection.getresponse();envelope=json.loads(response.read());connection.close()
            assert response.status==200 and 'result' in envelope,envelope
            return envelope['result']
        evidence=[]
        try:
            for _ in range(300):
                if process.poll() is not None:raise AssertionError('private daemon failed')
                try:rpc('capability_contract',{});break
                except (OSError,ValueError,KeyError):time.sleep(.02)
            else:raise AssertionError('private daemon readiness timeout')
            database=next(root.glob('*.sqlite*'))
            with sqlite3.connect(database) as db:
                assert db.execute('SELECT MAX(version) FROM schema_migrations').fetchone()[0]>=27
            result=subprocess.run(['swift','tools/test-resident-prop-editor-loop.swift',str(endpoint),str(root)],cwd=REPO,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
            args.log.write_bytes(result.stdout);print(result.stdout.decode(errors='replace'),end='');print('actual log:',args.log)
            result.check_returncode()
            with sqlite3.connect(database) as db:
                events=db.execute('SELECT state,run,session,claimed_at,receipt FROM agent_loop_events WHERE world=? AND scope=?',('room','resident')).fetchall()
            assert len(events)==2 and len({row[1] for row in events})==2,events
            assert all(row[0]=='cancelled' and row[2]=='fixture-host' and row[3] is not None and json.loads(row[4])['invocationStarted'] is True for row in events),events
            intent=rpc('resident_intent_restore',{'scope':{'worldID':'room','residentScope':'resident'}})
            assert intent['record']['value']['intentPausedByUser'] is True,intent
            evidence.append('PASS actual SQLite: 2 unique durable claims, 2 started/cancelled receipts retaining charged claimed_at; explicit user pause persisted; no unresolved/third event')
        finally:
            stop();stop()
            evidence.append('PASS double stop: owned private daemon PID and process group reaped; temporary root cleaned')
            with args.log.open('ab') as stream:
                stream.write(('\n'+'\n'.join(evidence)+'\n').encode())
            for line in evidence:print(line)

if __name__=='__main__':main()
