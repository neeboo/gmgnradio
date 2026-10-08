#!/usr/bin/env python3
"""Private actual Swift consumer + HTTP/SQLite removal and restart contracts."""
import argparse
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--run',action='store_true')
    parser.add_argument('--daemon',type=Path)
    args=parser.parse_args()
    if args.run and (args.daemon is None or not args.daemon.is_absolute()): parser.error('explicit absolute --daemon required')
    repo=Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='gmgn-presence-removal-') as temporary:
        parent=Path(temporary).resolve(); root=parent/'TaskService'; root.mkdir(mode=0o700)
        endpoint=root/'taskd.endpoint.json'; executable=parent/'consumer'
        source=repo/'apps/macos/Sources/GMGNRadio/Presence'
        flags=subprocess.check_output(['sh',str(repo/'tools/world-runtime-harness-flags.sh')],text=True).splitlines()
        subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-D','PRESENCE_REAL_HTTP',*flags,
            str(source/'WorldAuthorityClient.swift'),str(source/'TaskdHTTPTransport.swift'),str(source/'RetryBackoff.swift'),
            str(source/'RustPresenceSelectionClient.swift'),str(repo/'tools/fixtures/PresenceSelectionCompileSupport.swift'),
            str(repo/'tools/test-rust-presence-removal-client.swift'),'-o',str(executable)],check=True)
        if not args.run: print('PASS compile/link actual Swift6 selection client; no deletion/provider/UI'); return
        children=[]
        with open('/tmp/gmgn-presence-removal-private-daemon.log','w') as log:
            def start():
                endpoint.unlink(missing_ok=True)
                child=subprocess.Popen([str(args.daemon),'--root',str(root),'--endpoint-file',str(endpoint),'--concurrency','2'],stdout=log,stderr=log,start_new_session=True)
                children.append(child); print(f'PRIVATE PID/PGID={child.pid} root={root}',flush=True)
                for _ in range(1500):
                    assert child.poll() is None
                    if endpoint.exists(): return child
                    time.sleep(.02)
                raise AssertionError('readiness timeout')
            def stop(child):
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try: child.wait(timeout=5)
                    except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL); child.wait(timeout=5)
                for target in (lambda:os.kill(child.pid,0),lambda:os.killpg(child.pid,0)):
                    try: target(); raise AssertionError('child survived')
                    except ProcessLookupError: pass
                print(f'REAPED PID/PGID={child.pid} exit={child.returncode}',flush=True)
            serial=0
            def rpc(method,p):
                nonlocal serial
                serial+=1; descriptor=json.loads(endpoint.read_text()); host,port=descriptor['address'].split(':'); assert host=='127.0.0.1'
                connection=http.client.HTTPConnection(host,int(port),timeout=10)
                connection.request('POST','/rpc',json.dumps({'id':str(serial),'method':method,'params':p}),{'Authorization':'Bearer '+descriptor['token'],'Content-Type':'application/json'})
                response=connection.getresponse(); output=json.loads(response.read()); connection.close(); assert response.status==200; return output
            def ok(method,p):
                v=rpc(method,p); assert 'result' in v,(method,v); return v['result']
            def denied(method,p,code):
                v=rpc(method,p); assert v.get('error',{}).get('code')==code,(method,v,code)
            def seed(scope):
                packages=scope/'PresencePackages'; motions=scope/'MotionPackages'
                for directory,entry,manifest in [(packages/'test.pmx','model.pmx',{'id':'test.pmx','engine':'pmx'}),(motions/'test.vmd','clip.vmd',{'id':'test.vmd','format':'vmd','loop':False})]:
                    directory.mkdir(parents=True); (directory/entry).write_bytes(b'private native resource'); (directory/'manifest.json').write_text(json.dumps(dict(manifest,entry=entry)))
                return {'scope':str(scope),'requestID':'bind','packageRoot':str(packages),'motionRoot':str(motions),'policy':'native','supportedEngines':['orb','pmx'],
                    'avatars':[{'id':'builtin.orb','engine':'orb','builtIn':True,'rendererAvailable':True},{'id':'test.pmx','engine':'pmx','builtIn':False,'rendererAvailable':True,'path':str(packages/'test.pmx/model.pmx')}],
                    'motions':[{'id':'builtin.motion.natural-idle','format':'procedural','loop':True,'builtIn':True},{'id':'test.vmd','format':'vmd','loop':False,'builtIn':False,'path':str(motions/'test.vmd/clip.vmd')}]}
            try:
                child=start(); scope=parent/'NativeConsumer'; seed(scope)
                subprocess.run([str(executable),str(endpoint),str(scope)],check=True)
                read=ok('presence_selection_read',{'scope':str(scope)}); assert read['preferences']=={},read
                recovery=parent/'Recovery'; bind=seed(recovery); state=ok('presence_selection_bind_catalog',bind)
                intent={'scope':str(recovery),'requestID':'intent','hostSessionID':'original-host','expectedRevision':state['revision'],'kind':'avatars','id':'test.pmx'}
                q=ok('presence_selection_remove_intent',intent)
                stale=dict(intent,requestID='stale',expectedRevision=0)
                denied('presence_selection_remove_intent',stale,'presence_revision_conflict')
                claim={'scope':str(recovery),'requestID':'claim','hostSessionID':'original-host','expectedRevision':q['revision'],'intentID':'intent'}
                claimed=ok('presence_selection_remove_claim',claim); assert claimed['removal']['execute'] is True
                assert ok('presence_selection_remove_claim',claim)['removal']['execute'] is False
                target=recovery/'PresencePackages/test.pmx'; assert target.exists()
                # Lost response/restart must not authorize a second native deletion.
                stop(child); child=start()
                state=ok('presence_selection_read',{'scope':str(recovery)}); assert state['removal']['status']=='inflight' and state['removal']['execute'] is False and target.exists()
                denied('presence_selection_remove_receipt',claim,'presence_request_conflict')
                assert ok('presence_selection_remove_claim',claim)['removal']['execute'] is False
                wrong=dict(claim,requestID='new-host',expectedRevision=state['revision'],hostSessionID='replacement-host')
                denied('presence_selection_remove_claim',wrong,'presence_removal_identity_mismatch')
                receipt=dict(claim,requestID='receipt',expectedRevision=state['revision'],outcome='removed')
                denied('presence_selection_remove_receipt',dict(receipt,hostSessionID='replacement-host'),'presence_removal_identity_mismatch')
                denied('presence_selection_remove_receipt',receipt,'presence_removal_verification_failed')
                unknown=ok('presence_selection_remove_receipt',dict(receipt,requestID='unknown',outcome='unknown'))
                denied('presence_selection_remove_claim',dict(claim,requestID='replay-new',expectedRevision=unknown['revision']),'presence_removal_not_dispatchable')
                denied('presence_selection_bind_catalog',dict(bind,requestID='rebind-pending'),'presence_removal_pending')
                shutil.rmtree(target) # Exactly one private native leaf action, never formal data.
                receipt['expectedRevision']=unknown['revision']; done=ok('presence_selection_remove_receipt',receipt)
                assert done['removal']['status']=='removed'
                assert ok('presence_selection_remove_receipt',receipt)==done
                denied('presence_selection_remove_receipt',dict(receipt,outcome='failed'),'presence_request_conflict')
                database=next(p for p in root.glob('*.sqlite*') if not p.name.endswith(('-wal','-shm')))
                with sqlite3.connect(database) as db:
                    rows=db.execute('SELECT catalog,state FROM presence_selection').fetchall(); assert len(rows)==2
                    for cat,state in rows:
                        assert 'test.pmx' not in json.loads(cat)['avatars']
                        assert json.loads(state)['removal']['status']=='removed'
                print('PASS real HTTP/SQLite native deletion + CAS + duplicate claim/receipt + wrong host + restart unknown no replay',flush=True)
            finally:
                for child in children: stop(child)
    assert not parent.exists(); print('PASS exact private root removed',flush=True)

if __name__=='__main__': main()
