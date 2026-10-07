#!/usr/bin/env python3
"""Local HTTP fixtures exercise production Marble client/cache and formal package path."""
from pathlib import Path
import gzip
import http.server
import json
import struct
import subprocess
import tempfile
import threading
import time

repo = Path(__file__).resolve().parents[1]
products = repo / "tmp/unity-media-host/DerivedData/Build/Products/Release"
flags = subprocess.check_output(["sh", str(repo / "tools/world-runtime-harness-flags.sh")], text=True).splitlines()
spatial = (repo / "apps/macos/Sources/GMGNRadio/VisualEngine/SpatialStageStore.swift").read_text()
preset = "enum SpatialScenePreset" + spatial.split("enum SpatialScenePreset", 1)[1].split("struct ", 1)[0]
# The enum ends before unrelated renderer/store types.
preset = preset[:preset.index("\nenum Spatial")] if "\nenum Spatial" in preset else preset
marble = (repo / "apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift").read_text()
framing = "struct MarbleSceneFraming" + marble.split("struct MarbleSceneFraming", 1)[1].split("    func recommendedCameraHome", 1)[0]
framing += "    func colliderTransform" + marble.split("    func colliderTransform", 1)[1].split("    func normalizedSample", 1)[0]
framing += "    private static func trimmedBounds" + marble.split("    private static func trimmedBounds", 1)[1].split("enum MarbleAvatarLoadError", 1)[0]
public_catalog = ''
value_types = 'import Foundation\nimport WorldRuntime\nstruct BundledLivingWorldPackage: Sendable { let manifest: WorldManifest; let packageRoot: URL }\n'
# The library bridge uses this original enum; no SwiftUI scene is constructed.
settings = (repo / "apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift").read_text()
default = "enum DefaultSpacePreference" + settings.split("enum DefaultSpacePreference", 1)[1].split("@MainActor\nstruct GMGNSettingsView", 1)[0]
endpoint = "struct WorldAuthorityEndpoint" + (repo / "apps/macos/Sources/GMGNRadio/Presence/AuthorityWorldStatePersistence.swift").read_text().split("struct WorldAuthorityEndpoint", 1)[1]

with tempfile.TemporaryDirectory(prefix="gmgn-marble-pipeline-") as directory:
    temporary = Path(directory).resolve()
    fixture = temporary / "assets"
    fixture.mkdir()
    # Real v2 payload, four SH0 points with non-degenerate source bounds.
    positions = b"".join((int(value * 256) & 0xffffff).to_bytes(3, "little") for xyz in [(-2,0,-2),(2,0,2),(-2,3,2),(2,3,-2)] for value in xyz)
    raw = struct.pack("<IIIBBBB", 0x5053474e, 2, 4, 0, 8, 0, 0) + positions + bytes([128])*4 + bytes([128])*12 + bytes([128])*12 + bytes([128])*12
    (fixture / "scene.spz").write_bytes(gzip.compress(raw))
    for name, offset, replacement in [("unsupported-v3",4,struct.pack("<I",3)),("over-limit",8,struct.pack("<I",8_600_001)),("unsupported-sh",12,bytes([4])),("unsupported-bits",13,bytes([25]))]:
        altered = raw[:offset] + replacement + raw[offset+len(replacement):]
        (fixture / (name+".spz")).write_bytes(gzip.compress(altered))
    vertices = [(-20.,0.,-20.),(-20.,0.,20.),(20.,0.,-20.),(20.,0.,20.)]
    binary = b"".join(struct.pack("<fff", *v) for v in vertices) + struct.pack("<6H",0,1,2,2,1,3)
    gltf = {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"mode":4}]}],"buffers":[{"byteLength":len(binary)}],"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":12}],"accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}]}
    document = json.dumps(gltf,separators=(",",":")).encode()
    document += b" "*((-len(document))%4)
    glb = struct.pack("<III",0x46546c67,2,12+8+len(document)+8+len(binary)) + struct.pack("<II",len(document),0x4e4f534a)+document+struct.pack("<II",len(binary),0x004e4942)+binary
    (fixture / "collider.glb").write_bytes(glb)
    (fixture / "invalid-collider.glb").write_bytes(b"invalid")
    counts = {"generate":0,"download":0}
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def respond(self,data,status=200):
            self.send_response(status); self.send_header("Content-Length",str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length",0)))
            assert self.headers.get("WLT-Api-Key") == "isolated-http-key"
            assert json.loads(body)["world_prompt"]["type"] in ["text","image"]
            counts["generate"]+=1
            self.respond(json.dumps({"operation_id":"operation-exact","done":False}).encode())
        def do_GET(self):
            base = f"http://127.0.0.1:{self.server.server_port}"
            if self.path.startswith("/assets/"):
                counts["download"]+=1; self.respond((fixture / self.path.rsplit("/",1)[1]).read_bytes()); return
            if "operations" in self.path:
                self.respond(json.dumps({"operation_id":"operation-exact","done":True,"response":{"world_id":"world-exact"}}).encode()); return
            if "worlds/" in self.path:
                self.respond(json.dumps({"world":{"world_id":"world-exact","display_name":"gmgn DJ House","assets":{"mesh":{"collider_mesh_url":base+"/assets/collider.glb"},"splats":{"spz_urls":{"500k":base+"/assets/scene.spz"}}}}}).encode()); return
            self.respond(b"{}",404)
    server = http.server.ThreadingHTTPServer(("127.0.0.1",0),Handler)
    thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    support = temporary / "support"
    task_root = support / "gmgn radio/TaskService"
    task_root.mkdir(parents=True)
    endpoint_file = task_root / "taskd.endpoint.json"
    daemon = subprocess.Popen([str(repo/"target/debug/gmgn-taskd"),"--root",str(task_root),"--endpoint-file",str(endpoint_file),"--concurrency","2"],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    try:
        for _ in range(200):
            if endpoint_file.exists(): break
            assert daemon.poll() is None, "isolated daemon stopped"
            time.sleep(.01)
        assert endpoint_file.exists(), "isolated authority endpoint not ready"
        source = temporary / "types.swift"
        source.write_text(value_types + default + public_catalog + preset + framing + endpoint)
        executable = temporary / "test"
        subprocess.run(["swiftc","-swift-version","6","-parse-as-library",*flags,"-I",str(products),
            str(products/"SplatIO.o"),str(products/"PLYIO.o"),str(products/"spz.o"),"-lz",
            str(source), str(repo/"apps/macos/Sources/GMGNRadio/VisualEngine/MarbleWorld.swift"),
            str(repo/"apps/macos/Sources/GMGNRadio/VisualEngine/MarbleWorldClient.swift"),
            str(repo/"apps/macos/Sources/GMGNRadio/VisualEngine/MarbleWorldCache.swift"),
            str(repo/"apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift"),
            str(repo/"apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift"),
            str(repo/"apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift"),
            str(repo/"apps/macos/UnityHost/UnitySpaceLibraryBridge.swift"),
            str(repo/"apps/macos/UnityHost/UnityMarbleRuntimeDocument.swift"),
            str(repo/"apps/macos/UnityHost/UnityMarbleSPZFormat.swift"),
            str(repo/"apps/macos/UnityHost/UnityMarbleWorldBridge.swift"),
            str(repo/"apps/macos/UnityHost/UnityMarbleAuthorityRegistration.swift"),
            str(repo/"tools/test-unity-marble-pipeline.swift"),"-o",str(executable)],check=True)
        subprocess.run([str(executable),str(support),f"http://127.0.0.1:{server.server_port}",str(fixture),str(endpoint_file)],check=True)
        assert counts["generate"] == 1 and counts["download"] == 2, counts
        print("PASS production HTTP generate/poll/exact-world lookup + two actual downloads + real isolated taskd registration/readback; no external network or user credentials")
    finally:
        server.shutdown(); server.server_close()
        daemon.terminate()
        try: daemon.wait(timeout=5)
        except subprocess.TimeoutExpired: daemon.kill(); daemon.wait(timeout=5)
