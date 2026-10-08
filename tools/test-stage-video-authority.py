#!/usr/bin/env python3
"""Compile the production store/transport; optionally run against private SQLite only."""
import argparse, pathlib, tempfile, subprocess, time, os, signal, sqlite3
parser=argparse.ArgumentParser()
parser.add_argument("--run",action="store_true")
parser.add_argument("--daemon",type=pathlib.Path)
args=parser.parse_args()
if args.run and (not args.daemon or not args.daemon.is_absolute()):parser.error("--run requires explicit absolute private --daemon")
repo=pathlib.Path(__file__).resolve().parents[1]
def declaration(source,marker):
    start=source.index(marker);opening=source.index("{",start);depth=1;end=opening+1
    while depth:
        depth += (source[end]=="{")-(source[end]=="}");end+=1
    return source[start:end]
authority=(repo/"apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift").read_text()
support="import Foundation\nimport os\n"+"\n".join(declaration(authority,m) for m in ["enum WorldAuthorityError", "final class TaskdHTTPAuthorityClient", "private final class WorldHTTPResponse"])
support += "\n"+declaration((repo/"apps/macos/Sources/GMGNRadio/VisualEngine/StageVisualPresetTimeline.swift").read_text(),"enum StageVisualMood")
support += "\n"+declaration((repo/"apps/macos/Sources/GMGNRadio/DJCore/ProgramPlanner.swift").read_text(),"enum ProgramSlotRole")
# Renderer frame/palette DTOs are not exercised by this authority fixture.
support += "\nstruct ProgramVisualCue: Sendable { let role:ProgramSlotRole;let mood:StageVisualMood }\n"
with tempfile.TemporaryDirectory(prefix="gmgn-stage-video-authority-") as directory:
    root=pathlib.Path(directory).resolve();generated=root/"support.swift";generated.write_text(support)
    binary=root/"consumer"
    subprocess.run(["swiftc","-swift-version","6","-parse-as-library",str(generated),
        str(repo/"apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift"),
        str(repo/"apps/macos/Sources/GMGNRadio/VisualEngine/StageVideoPlayback.swift"),
        str(repo/"apps/macos/Sources/GMGNRadio/VisualEngine/RustStageVideoClient.swift"),
        str(repo/"tools/test-stage-video-authority.swift"),"-o",str(binary)],check=True)
    print("PASS actual Swift6 store/client/authenticated transport compile/link",flush=True)
    if args.run:
        service=root/"service";service.mkdir(mode=0o700);endpoint=service/"taskd.endpoint.json"
        with open("/tmp/gmgn-stage-video-private-daemon.log","w") as log:
            daemon=subprocess.Popen([str(args.daemon),"--root",str(service),"--endpoint-file",str(endpoint),"--concurrency","2"],stdout=log,stderr=log,start_new_session=True)
            try:
                for _ in range(1000):
                    if endpoint.exists():break
                    assert daemon.poll() is None,"private daemon stopped";time.sleep(.01)
                assert endpoint.exists(),"private endpoint absent"
                subprocess.run([str(binary),str(endpoint),str(root)],check=True,timeout=120)
                database=service/"tasks.sqlite3"
                with sqlite3.connect(database) as sql:
                    count=sql.execute("SELECT COUNT(*) FROM stage_video_state").fetchone()[0]
                    assert count==5,count
                    print("PASS private SQLite contains five isolated scopes, no second database writer",flush=True)
                os.killpg(daemon.pid,signal.SIGTERM);daemon.wait(timeout=10)
                print(f"CLEANUP first private daemon {daemon.pid} exit={daemon.returncode}",flush=True)
                endpoint.unlink(missing_ok=True)
                daemon=subprocess.Popen([str(args.daemon),"--root",str(service),"--endpoint-file",str(endpoint),"--concurrency","2"],stdout=log,stderr=log,start_new_session=True)
                for _ in range(1000):
                    if endpoint.exists():break
                    assert daemon.poll() is None,"restarted private daemon stopped";time.sleep(.01)
                assert endpoint.exists(),"restarted endpoint absent"
                subprocess.run([str(binary),str(endpoint),str(root),"restart"],check=True,timeout=120)
            finally:
                if daemon.poll() is None:os.killpg(daemon.pid,signal.SIGTERM)
                try:daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:os.killpg(daemon.pid,signal.SIGKILL);daemon.wait()
                print(f"CLEANUP private daemon {daemon.pid} exit={daemon.returncode}; temporary root removed on exit",flush=True)
