#!/usr/bin/env python3
"""Real isolated taskd CAS/restart probe; does not substitute Unity UI acceptance."""
import argparse
import copy
import json
import pathlib
import socket
import subprocess
import tempfile
import time
import uuid


def run(args):
    repo = pathlib.Path(__file__).resolve().parent.parent
    bundle = pathlib.Path(args.bundle).resolve()
    subprocess.run(["python3", str(repo / "tools/world-backup/world_backup.py"),
                    "verify", "--bundle", str(bundle)], check=True, capture_output=True)
    document = json.loads((bundle / "worlds.json").read_text())
    records = [r for r in document["records"] if r["world_id"] == args.world_id and r["tombstone"] == 0]
    state = copy.deepcopy(next(r["value"] for r in records if r["domain"] == "worlds" and r["key"] == "state"))
    state["objectStates"] = {r["key"]: copy.deepcopy(r["value"]) for r in records if r["domain"] == "objects"}
    base = pathlib.Path(tempfile.mkdtemp(prefix="unity-authority-e2e-", dir=repo / "tmp"))
    root = base / "gmgn radio" / "TaskService"
    root.mkdir(parents=True)
    endpoint = root / "taskd.endpoint.json"
    daemon = None
    log = (base / "daemon.log").open("w")

    def start():
        nonlocal daemon
        if endpoint.exists():
            endpoint.unlink()  # Only this probe's known stale endpoint, never production.
        daemon = subprocess.Popen([args.daemon, "--root", str(root), "--endpoint-file", str(endpoint),
                                   "--concurrency", "1"], stdout=log, stderr=log)
        for _ in range(100):
            if endpoint.exists():
                return
            if daemon.poll() is not None:
                raise RuntimeError("isolated daemon exited before endpoint")
            time.sleep(.05)
        raise RuntimeError("isolated daemon startup timeout")

    def rpc(method, params):
        e = json.loads(endpoint.read_text())
        host, port = e["address"].split(":")
        assert host == "127.0.0.1"
        with socket.create_connection((host, int(port)), timeout=5) as stream:
            stream.sendall((json.dumps({"id": str(uuid.uuid4()), "auth": e["token"],
                                       "method": method, "params": params}) + "\n").encode())
            reply = json.loads(stream.makefile("rb").readline())
        return reply

    def snapshot():
        response = rpc("world_snapshot", {"worldID": args.world_id, "includeState": True})
        assert "error" not in response
        return response["result"]["record"]

    try:
        start()
        assert snapshot() is None
        seed = {"worldID": args.world_id, "requestID": "isolated-backup:" + str(uuid.uuid4()),
                "expectedRevision": 0, "producer": "unity", "intent": {"kind": "isolated-backup-recovery"},
                "ops": [{"op": "replaceState", "state": state}]}
        imported = rpc("world_commit", seed)
        assert "error" not in imported, imported.get("error", {}).get("code")
        before = snapshot()
        edited = copy.deepcopy(before["state"])
        object_id = next(k for k, v in edited["objectStates"].items() if v["isEnabled"])
        edited["objectStates"][object_id]["transform"]["position"]["x"] += .25
        edited["revision"] += 1
        request = {"worldID": args.world_id, "requestID": "unity-layout:" + str(uuid.uuid4()),
                   "expectedRevision": before["recordRevision"], "producer": "unity",
                   "intent": {"kind": "move", "objectID": object_id}, "ops": [{"op": "replaceState", "state": edited}]}
        committed = rpc("world_commit", request)
        assert "error" not in committed, committed.get("error", {}).get("code")
        after = snapshot()
        assert after["recordRevision"] == committed["result"]["revision"]
        assert after["state"] == edited
        replay = rpc("world_commit", request)
        assert replay["result"]["replayed"] is True
        stale = copy.deepcopy(request)
        stale["requestID"] = "stale:" + str(uuid.uuid4())
        stale["ops"][0]["state"]["revision"] += 1
        rejected = rpc("world_commit", stale)
        assert rejected["error"]["code"] == "revision_conflict"
        assert snapshot()["state"] == edited
        daemon.terminate()
        daemon.wait(timeout=10)
        start()
        restarted = snapshot()
        assert restarted["state"] == edited
        assert restarted["recordRevision"] == after["recordRevision"]
        print(json.dumps({"scope": "real-isolated-rust-protocol-not-unity-ui", "root": str(base),
                          "objects": len(edited["objectStates"]), "seedRevision": before["recordRevision"],
                          "savedRevision": after["recordRevision"], "casConflictRejected": True,
                          "idempotentReplay": True, "restartRecovery": True}))
    finally:
        if daemon is not None and daemon.poll() is None:
            daemon.terminate()
            daemon.wait(timeout=10)
        log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--world-id", required=True)
    parser.add_argument("--daemon", required=True)
    run(parser.parse_args())
