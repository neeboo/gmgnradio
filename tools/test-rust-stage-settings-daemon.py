#!/usr/bin/env python3
"""Actual product client + extracted native consumer methods, private HTTP/SQLite.
No UI/rendering/lyrics parser/audio acceptance; DTO/platform leaves are explicit.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time

def section(text,start,end):
    a=text.index(start); return text[a:text.index(end,a)]

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--run',action='store_true'); parser.add_argument('--daemon',type=Path); parser.add_argument('--repeat',type=int,default=1); args=parser.parse_args()
    if args.run and (args.daemon is None or not args.daemon.is_absolute()): parser.error('explicit root-approved absolute --daemon required')
    repo=Path(__file__).resolve().parents[1]; source=repo/'apps/macos/Sources/GMGNRadio'
    with tempfile.TemporaryDirectory(prefix='gmgn-stage-settings-http-') as temporary:
        parent=Path(temporary).resolve(); native=parent/'NativeConsumers.swift'; executable=parent/'consumer'
        visual=(source/'VisualEngine/StageVisualPresetTimeline.swift').read_text(); spatial=(source/'VisualEngine/SpatialStageStore.swift').read_text(); lyrics=(source/'VisualEngine/StagePresentationModel.swift').read_text()
        visual_class=section(visual,'@MainActor\nfinal class StageVisualDirectionStore','\nstruct StageVisualPresetTimeline')
        mutations=section(spatial,'    func setAvatarPosition(','    /// Applies a world-space offset')
        projection=section(spatial,'    private func installBaseAvatarPlacement(','    func setWorldVisible(')
        lyric_enum=section(lyrics,'enum StageLyricsVisualMode:','\nenum StageLyricTypography')
        lyric_store=section(lyrics,'@MainActor\nfinal class StageLyricsStore','\nstruct StageTextCue')
        assert 'defaults.set' not in visual_class+mutations+projection+lyric_store
        wrapper='''
@MainActor final class SpatialStageStore {
 let settings:RustProductSettingsClient
 var settingsError:String?
 var selectedWorldID:String?="private-world"
 var selectedScene=FixtureScene.djHouse
 var baseAvatarPlacement=StageAvatarPlacement(position:SIMD3<Float>(0.1,-0.09,-0.75),scale:1,yaw:0)
 var stableAvatarPlacement=StageAvatarPlacement(position:SIMD3<Float>(0.1,-0.09,-0.75),scale:1,yaw:0)
 var avatarPlacement=StageAvatarPlacement(position:SIMD3<Float>(0.1,-0.09,-0.75),scale:1,yaw:0)
 var transientAvatarPlacement:StageAvatarPlacement?
 init(settings:RustProductSettingsClient){self.settings=settings}
 func awaitSettingsReady() async throws {try await settings.ensureLoaded()}
 func installAvatarPlacement(_ placement:StageAvatarPlacement){installBaseAvatarPlacement(placement)}
'''
        native.write_text('import Foundation\nimport Combine\n'+visual_class+wrapper+mutations+projection+'\n}\n'+lyric_enum+lyric_store)
        flags=subprocess.check_output(['sh',str(repo/'tools/world-runtime-harness-flags.sh')],text=True).splitlines()
        subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-D','PRESENCE_REAL_HTTP',*flags,
            str(source/'Presence/WorldAuthorityClient.swift'),str(source/'Presence/TaskdHTTPTransport.swift'),str(source/'Presence/RetryBackoff.swift'),
            str(source/'Presence/RustPresenceSelectionClient.swift'),str(source/'Presence/RustProductSettingsClient.swift'),
            str(repo/'tools/fixtures/PresenceSelectionCompileSupport.swift'),str(native),str(repo/'tools/test-rust-stage-settings-client.swift'),'-o',str(executable)],check=True)
        if not args.run: print('PASS compile/link actual typed client + production native consumer methods; no runtime'); return
        children=[]
        with open('/tmp/gmgn-stage-settings-private-daemon.log','w') as log:
            def start(root):
                endpoint=root/'taskd.endpoint.json'; endpoint.unlink(missing_ok=True)
                child=subprocess.Popen([str(args.daemon),'--root',str(root),'--endpoint-file',str(endpoint),'--concurrency','2'],stdout=log,stderr=log,start_new_session=True)
                children.append(child); print(f'PRIVATE PID/PGID={child.pid} root={root}',flush=True)
                for _ in range(1500):
                    assert child.poll() is None
                    if endpoint.exists(): return child,endpoint
                    time.sleep(.02)
                raise AssertionError('private readiness timeout')
            def stop(child):
                if child.poll() is None:
                    os.killpg(child.pid,signal.SIGTERM)
                    try: child.wait(timeout=5)
                    except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL); child.wait(timeout=5)
                for probe in (lambda:os.kill(child.pid,0),lambda:os.killpg(child.pid,0)):
                    try: probe(); raise AssertionError('private child survived')
                    except ProcessLookupError: pass
                print(f'REAPED PID/PGID={child.pid} exit={child.returncode}',flush=True)
            try:
                for iteration in range(args.repeat):
                  for mode in ('stage-first','global-first'):
                    root=parent/(mode+'-'+str(iteration)); root.mkdir(mode=0o700); marker=root/'seeded-marker'
                    child,endpoint=start(root)
                    result=subprocess.run([str(executable),str(endpoint),mode,str(marker)])
                    if result.returncode:
                        for dbpath in root.glob('*.sqlite*'):
                            if dbpath.name.endswith(('-wal','-shm')): continue
                            with sqlite3.connect(dbpath) as evidence:
                                print('FAIL JOURNAL metadata only:',evidence.execute('SELECT request,digest FROM product_settings_requests ORDER BY rowid').fetchall(),flush=True)
                        raise AssertionError(f'consumer exit {result.returncode}')
                    assert marker.read_text()=='seeded'
                    database=next(p for p in root.glob('*.sqlite*') if not p.name.endswith(('-wal','-shm')))
                    with sqlite3.connect(database) as db:
                        row=db.execute("SELECT revision,value,imported FROM product_settings WHERE profile='product'").fetchone(); value=json.loads(row[1])
                        assert row[2]==1 and value['locale']=='ja' and value['residentPersona']=='private legacy persona'
                        assert value['stagePointCloudChoice']=='galaxyField' and value['stageLyricsResolvedMode']=='article'
                        assert 'world.private-world' not in value['avatarPositions']
                        count=db.execute('SELECT count(*) FROM product_settings_requests').fetchone()[0]
                    stop(child); child,endpoint=start(root)
                    subprocess.run([str(executable),str(endpoint),'reopen',str(marker)],check=True)
                    with sqlite3.connect(database) as db:
                        assert db.execute('SELECT count(*) FROM product_settings_requests').fetchone()[0]==count
                        assert db.execute("SELECT revision FROM product_settings WHERE profile='product'").fetchone()[0]==row[0]
                    stop(child)
                    print(f'PASS {mode}: actual SQLite import order, durable state, restart no replay',flush=True)
            finally:
                for child in children: stop(child)
    assert not parent.exists(); print('PASS exact private root removed',flush=True)

if __name__=='__main__': main()
