#!/usr/bin/env python3
"""Real private issued speech; device/provider stream only are simulated."""
import argparse, os, pathlib, signal, sqlite3, subprocess, tempfile, time
repo=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--daemon',default=os.environ.get('TASKD_BIN',str(repo/'target/debug/gmgn-taskd')));args=p.parse_args()
def decl(s,m):
    start=s.index(m);end=s.index('{',start)+1;depth=1
    while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
    return s[start:end]
def read(p):return (repo/p).read_text()
settings=read('apps/macos/UnityHost/UnityProductSettings.swift');host=read('apps/macos/UnityHost/UnityMediaHost.swift')
assert 'private var replySpeech: RustSpeechSynthesizer?' in settings
assert 'productSettings.replySpeechEvent(requestID: String(id.uint64Value), kind: "accepted")' in host
assert 'productSettings.replySpeechEvent(requestID: String(id.uint64Value), kind: "cancelled")' in host
assert 'source: event["speechSource"] as? [String: Any]' in host
authority=read('apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift')
support='import Foundation\nimport os\n'+'\n'.join(decl(authority,m) for m in ['enum WorldAuthorityError','final class TaskdHTTPAuthorityClient','private final class WorldHTTPResponse'])
support+='\n'+decl(read('apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift'),'struct AgentSpeechPlaybackState')
support+='\n'+decl(read('apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift'),'enum AgentSpeechOutcome')+'\ntypealias AgentSpeechCompletion = @MainActor (AgentSpeechOutcome) -> Void\n'
support+='\n'+read('apps/macos/Sources/GMGNRadio/AudioEngine/DuckingEnvelope.swift')
support+='\n@MainActor final class Graph { let duckingController=Mixer();var djIsSpeaking=false,residentSpeechPlaying=false;var musicVolume:Float=0.72\n'+decl(read('apps/macos/Sources/GMGNRadio/AudioEngine/AudioGraphController.swift'),'    func setResidentSpeechPlaying(')+'\n}\n'
fields=read('tools/privatefixtures/unity-reply-speech.swift').split('// SETTINGS FIELDS BEGIN\n')[1].split('// SETTINGS FIELDS END')[0]
methods=settings[settings.index('    var replyPlaybackSnapshot:'):settings.index('    func close()',settings.index('    var replyPlaybackSnapshot:'))]
support+='\n@MainActor final class Settings {\n'+fields+methods+'\n}\n'
route=host.split('                guard let request = event["requestID"] as? NSNumber else { continue }',1)[1].split('\n            }\n        }\n        conversation["capabilities"]',1)[0]
support+='\n@MainActor final class Host { let productSettings:Settings;init(_ settings:Settings){productSettings=settings}\nfunc send(_ id:NSNumber){productSettings.replySpeechEvent(requestID: String(id.uint64Value), kind: "accepted")}\nfunc cancel(_ id:NSNumber){productSettings.replySpeechEvent(requestID: String(id.uint64Value), kind: "cancelled")}\nfunc poll(_ events:[[String:Any]]){for event in events { guard let request = event["requestID"] as? NSNumber else {continue}\n'+route+'\n}}}\n'
with tempfile.TemporaryDirectory(prefix='gmgn-unity-reply-private-') as directory:
    root=pathlib.Path(directory).resolve();service=root/'service';service.mkdir(mode=0o700);endpoint=service/'taskd.endpoint.json'
    source=root/'support.swift';source.write_text(support);binary=root/'checks'
    subprocess.run(['swiftc','-j1','-swift-version','6','-parse-as-library',str(source)]+[str(repo/'apps/macos/Sources/GMGNRadio'/s) for s in ['Presence/TaskdHTTPTransport.swift','Agent/RustVoiceClient.swift','Agent/RustSpeechDeliveryClient.swift','Agent/StreamingPCMPlayer.swift']]+[str(repo/'tools/privatefixtures/unity-reply-speech.swift'),'-o',str(binary)],check=True)
    print('PASS Swift6 production reply routing and issued playback compile',flush=True)
    with open(root/'daemon.log','w') as log:
        daemon=subprocess.Popen([args.daemon,'--root',str(service),'--endpoint-file',str(endpoint),'--concurrency','2'],stdout=log,stderr=log,start_new_session=True)
        print(f'OWNED root={root} PID={daemon.pid} PGID={daemon.pid}',flush=True)
        try:
            for _ in range(1000):
                if endpoint.exists():break
                assert daemon.poll() is None;time.sleep(.01)
            assert endpoint.exists()
            # Only historical model results are seeded; all transitions use HTTP.
            with sqlite3.connect(service/'tasks.sqlite3') as sql:
                for i in range(1,11):sql.execute("INSERT INTO chat_requests(backend,scope,request,host_session,digest,state,reply) VALUES('codex','private-chat',?,'model-host','fixture','completed',?)",(str(i),f'confirmed reply {i}'))
            subprocess.run([str(binary),str(endpoint)],check=True,timeout=90)
            with sqlite3.connect(service/'tasks.sqlite3') as sql:
                lanes=sql.execute('SELECT request,state FROM chat_speech_lanes ORDER BY scope').fetchall();assert any(s=='suppressed' for _,s in lanes),lanes
                print(f'PASS private SQLite lanes={lanes}',flush=True)
        finally:
            if daemon.poll() is None:os.killpg(daemon.pid,signal.SIGTERM)
            try:daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(daemon.pid,signal.SIGKILL);daemon.wait()
            print(f'CLEANUP PID={daemon.pid} PGID={daemon.pid} exit={daemon.returncode}; private root removed on exit',flush=True)
