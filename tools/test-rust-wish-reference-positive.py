#!/usr/bin/env python3
"""Actual scheduler/CLI ledger -> production Swift reference consumer, offline."""
import base64
import http.server
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid

REPO=Path(__file__).resolve().parents[1]
PNG=base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6WQAAAAASUVORK5CYII=")
class RawImage(http.server.BaseHTTPRequestHandler):
    requests=0
    def do_GET(self):
        assert self.path == "/reference.png"
        type(self).requests += 1
        self.send_response(200);self.send_header("Content-Type","image/png");self.end_headers();self.wfile.write(PNG)
    def log_message(self,*args): pass

with tempfile.TemporaryDirectory(prefix="gmgn-reference-positive-") as tmp:
    fixture=Path(tmp).resolve();root=fixture/"taskd";root.mkdir();endpoint=root/"endpoint.json"
    # Extract the same production transport/TaskLocal boundaries used by the
    # negative fixture; only native coordinator/download leaves differ.
    production=(REPO/"apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift").read_text()
    error=production[production.index("enum WorldAuthorityError:"):production.index("/// 一条权威事实")]
    http_source=production[production.index("/// Local HTTP authority transport"):production.index("/// 世界状态权威的门面")]
    session=(REPO/"apps/macos/Sources/GMGNRadio/Agent/ResidentWorldToolSession.swift").read_text()
    authority=session[session.index("    struct RustDispatchAuthority:"):session.index("    /// Supplied by the host's real request")]
    additional=session[session.index("    struct AdditionalTool {"):session.index("    struct CallRecord:")]
    result=(REPO/"apps/macos/Sources/GMGNRadio/VoiceSession/RealtimeDJSession.swift").read_text()
    result=result[result.index("struct RealtimeDJToolResult:"):result.index("struct RealtimeDJFailure:")]
    extracted=fixture/"Boundaries.swift"
    extracted.write_text("import Foundation\nimport OSLog\n"+error+http_source+result+"\n@MainActor final class ResidentWorldToolSession {\n"+authority+additional+"}\n")
    sources=["apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift","apps/macos/Sources/GMGNRadio/Agent/RustWishReferenceClient.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentWishReferenceTools.swift","apps/macos/Sources/GMGNRadio/Agent/ResidentWishReferenceDiagnosis.swift","tools/test-rust-wish-reference-positive.swift"]
    consumer=fixture/"consumer"
    subprocess.run(["swiftc","-swift-version","6","-parse-as-library",str(extracted)]+[str(REPO/p) for p in sources]+["-o",str(consumer)],check=True,timeout=120)
    cli=(REPO/"services/gmgn-taskd/src/agent_cli.rs").read_text()
    mock=re.search(r'const MOCK: &str = r#"(.*?)"#;',cli,re.S).group(1)
    mock=mock.replace("'tool':'move','arguments':{'target':'chair'}","'tool':'register_wish_reference_image','arguments':{'image_url':'https://fixture.example/reference.png','display_name':'private chair'}")
    executable=fixture/"raw-provider-cli";executable.write_text(mock);executable.chmod(0o700)
    features=re.findall(r'"([^"]+)"',re.search(r'const FEATURES:.*?= &\[(.*?)\];',cli,re.S).group(1))
    overrides=[f"features.{f}=false" for f in features]+["agents.enabled=false","notify=[]",'web_search="live"','cli_auth_credentials_store="file"','mcp_oauth_credentials_store="file"']
    arguments=["app-server","--stdio"]
    for value in overrides: arguments.extend(["-c",value])
    log=(fixture/"daemon.log").open("wb")
    daemon=subprocess.Popen([str(REPO/"target/debug/gmgn-taskd"),"--root",str(root),"--endpoint-file",str(endpoint),"--concurrency","1"],stdout=log,stderr=log,start_new_session=True)
    server=http.server.ThreadingHTTPServer(("127.0.0.1",0),RawImage)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    cli_identity=None
    def rpc(method,params):
        descriptor=json.loads(endpoint.read_text())
        request=urllib.request.Request("http://"+descriptor["address"]+"/rpc",data=json.dumps({"id":"private-positive","method":method,"params":params}).encode(),headers={"Authorization":"Bearer "+descriptor["token"],"Content-Type":"application/json"})
        reply=json.load(urllib.request.urlopen(request,timeout=10))
        assert "error" not in reply,(method,reply)
        return reply["result"]
    def phase(identity,wanted):
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            state=rpc("agent_cli_read",identity)
            for pending in state.get("pendingTools",[]):
                if pending["phase"]==wanted:return pending
            assert state["state"] not in ["failed","unknown","cancelled"],state
            time.sleep(.025)
        raise AssertionError("CLI phase timeout: "+wanted)
    try:
        for _ in range(300):
            if endpoint.exists() and json.loads(endpoint.read_text()).get("version")==2:break
            assert daemon.poll() is None
            time.sleep(.025)
        else:raise AssertionError("daemon timeout")
        identity={"worldID":"private-positive-world","residentScope":"private-positive-scope","hostSessionID":"private-host"}
        rpc("agent_loop_configure",dict(identity,hourlyLimit=6,minimumWakeIntervalSeconds=1))
        rpc("agent_loop_enqueue",dict(identity,eventID="human-event",intentID="human-intent",kind="human",intentState="active",command={},messageIDs=["human-message"],inputRefs={"human-message":{"text":"登记参考图"}}))
        run=str(uuid.uuid4());claimed=rpc("agent_loop_claim",dict(identity,runID=run,nowMillis=int(time.time()*1000)))
        assert claimed["claimed"] is True
        schema={"type":"object","properties":{"image_url":{"type":"string"},"display_name":{"type":"string"}},"required":["image_url","display_name"],"additionalProperties":False}
        cli_identity=dict(identity,runID=run,eventID=claimed["eventID"],executable=str(executable),arguments=arguments,environment={"USER":"fixture"},root=str(fixture),cwd=str(fixture),input=[{"type":"text","text":"登记参考图","text_elements":[]}],tools=[{"name":"register_wish_reference_image","description":"register","effect":"write","inputSchema":schema}])
        rpc("agent_cli_start",cli_identity)
        proposed=phase(cli_identity,"authorize");rpc("agent_cli_authorize",dict(proposed,decision="approved",operationID="private-reference-operation"))
        pending=phase(cli_identity,"execute")
        with sqlite3.connect(root/"tasks.sqlite3") as db:
            row=db.execute("SELECT state,operation,tool FROM agent_tool_calls").fetchone()
            assert row==("inflight","private-reference-operation","register_wish_reference_image"),row
        context=fixture/"dispatch.json";context.write_text(json.dumps(pending))
        completed=subprocess.run([str(consumer),str(endpoint),str(context),f"http://127.0.0.1:{server.server_port}/reference.png",str(fixture/"images")],timeout=30)
        print("CONSUMER EXIT:",completed.returncode,flush=True);assert completed.returncode==0
        rpc("agent_cli_tool_receipt",dict(pending,status="completed",output={"registered":True}))
        with sqlite3.connect(root/"tasks.sqlite3") as db:
            rows=db.execute("SELECT state FROM wish_reference_urls").fetchall();assert rows==[("registered",)],rows
            assert db.execute("SELECT COUNT(*) FROM wish_reference_calls").fetchone()[0]==1
            archive=json.loads(db.execute("SELECT payload FROM wish_control_documents WHERE owner='positive-fixture'").fetchone()[0])
            assert len(archive["webReferences"])==1 and len(archive["authorizations"])==1
            assert db.execute("SELECT state FROM agent_tool_calls").fetchone()[0]=="finished"
        assert RawImage.requests==1
        print("PASS: SQLite actual human claimed event, ledger inflight→finished, reference registered=1, calls=1, wish grant=1 reference=1; localhost raw PNG GET=1; Commons search NOT tested",flush=True)
    finally:
        if cli_identity:
            try:rpc("agent_cli_cancel",cli_identity)
            except Exception:pass
        server.shutdown();server.server_close();thread.join(timeout=3)
        if daemon.poll() is None:
            os.killpg(daemon.pid,signal.SIGTERM)
            try:daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(daemon.pid,signal.SIGKILL);daemon.wait(timeout=5)
        log.close()
        print(f"CLEANUP: exact private daemon PGID {daemon.pid} exited={daemon.returncode}; raw localhost server closed; temporary root {fixture} removed on context exit",flush=True)
