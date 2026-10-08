#!/usr/bin/env python3
"""Real private HTTP/SQLite/blob geometry contracts, with deterministic raw probe facts.

No Unity renderer or native physics acceptance is claimed. No provider/credentials/audio.
"""
import argparse
import copy
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--daemon", type=Path)
    args = parser.parse_args()
    if not args.run:
        print("READY private geometry HTTP fixture; --run requires root-approved --daemon")
        return
    if args.daemon is None or not args.daemon.is_absolute():
        parser.error("--run requires an explicit absolute --daemon")
    with tempfile.TemporaryDirectory(prefix="gmgn-marble-geometry-http-") as directory:
        parent = Path(directory).resolve()
        root = parent / "TaskService"
        root.mkdir(mode=0o700)
        blobs = root / "blobs"
        blobs.mkdir(mode=0o700)
        endpoint = root / "taskd.endpoint.json"
        with open("/tmp/gmgn-marble-geometry-private-daemon.log", "w") as log:
            daemon = subprocess.Popen([str(args.daemon), "--root", str(root), "--endpoint-file", str(endpoint), "--concurrency", "2"],
                                      stdout=log, stderr=log, start_new_session=True)
            print(f"PRIVATE daemon PID/PGID={daemon.pid} root={root}", flush=True)
            serial = 0

            def rpc(method, params):
                nonlocal serial
                serial += 1
                descriptor = json.loads(endpoint.read_text())
                host, port = descriptor["address"].split(":")
                assert host == "127.0.0.1"
                connection = http.client.HTTPConnection(host, int(port), timeout=10)
                connection.request("POST", "/rpc", json.dumps({"id": str(serial), "method": method, "params": params}),
                                   {"Authorization": "Bearer " + descriptor["token"], "Content-Type": "application/json"})
                response = connection.getresponse()
                result = json.loads(response.read())
                connection.close()
                assert response.status == 200, response.status
                return result

            def ok(method, params):
                result = rpc(method, params)
                assert "result" in result, (method, result)
                return result["result"]

            def denied(method, params, code):
                result = rpc(method, params)
                assert result.get("error", {}).get("code") == code, (method, result, code)

            def put(value):
                raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
                sha = hashlib.sha256(raw).hexdigest()
                path = blobs / sha
                path.write_bytes(raw)
                result = ok("world_blob_put", {"sha256": sha, "mime": "application/json", "localPath": str(path)})
                assert result["sha256"] == sha and result["bytes"] == len(raw)
                return sha, path, raw

            try:
                for _ in range(1500):
                    assert daemon.poll() is None, "private daemon exited"
                    if endpoint.exists():
                        try:
                            ok("marble_geometry_sample_plan", {"pointCount": 4})
                            break
                        except (OSError, ValueError):
                            pass
                    time.sleep(.02)
                else:
                    raise AssertionError("private daemon readiness timeout")
                sample = ok("marble_geometry_sample_plan", {"pointCount": 4})
                assert sample["indices"] == [0, 1, 2, 3] and sample["sampleStride"] == 1
                large = ok("marble_geometry_sample_plan", {"pointCount": 8600000})
                assert large["sampleStride"] == 215 and len(large["indices"]) == 40000
                denied("marble_geometry_sample_plan", {"pointCount": 0}, "marble_geometry_invalid_input")
                denied("marble_geometry_sample_plan", {"pointCount": 8600001}, "marble_geometry_invalid_input")
                triangles = [[[-3, 0, -3], [3, 0, -3], [0, 0, 6]], [[-3, 0, 3], [3, 0, 3], [0, 0, -6]]]
                first, first_path, first_bytes = put({"offset": 0, "triangles": [triangles[0]]})
                second, _, _ = put({"offset": 1, "triangles": [triangles[1]]})
                positions = [[-2, 0, -2], [2, 0, 2], [-2, 3, 2], [2, 3, -2]]
                geometry = {"sourcePointCount": 4, "samples": [{"index": i, "position": p} for i, p in enumerate(positions)],
                            "sourceCoordinates": "glTF", "triangleCount": 2, "triangleChunks": [first, second]}

                def plan(g, **kwargs):
                    return {"geometry": g, "offset": 0, "limit": 1, **kwargs}

                page = ok("marble_geometry_plan", plan(geometry))
                assert page["probeCount"] == 2 and page["nextOffset"] == 1
                assert page["probes"][0]["key"] == "triangle:0"
                next_page = ok("marble_geometry_plan", plan(geometry, offset=1, planHash=page["planHash"]))
                assert next_page["nextOffset"] is None and next_page["probes"][0]["key"] == "triangle:1"
                denied("marble_geometry_plan", plan(geometry, planHash="0" * 64), "marble_geometry_plan_mismatch")
                missing = copy.deepcopy(geometry); missing["triangleChunks"] = ["e" * 64]
                denied("marble_geometry_plan", plan(missing), "marble_geometry_invalid_proof")
                reordered = copy.deepcopy(geometry); reordered["triangleChunks"] = [second, first]
                denied("marble_geometry_plan", plan(reordered), "marble_geometry_invalid_proof")
                omitted = copy.deepcopy(geometry); omitted["triangleChunks"] = [first]
                denied("marble_geometry_plan", plan(omitted), "marble_geometry_incomplete_proof")
                shifted_index = copy.deepcopy(geometry); shifted_index["samples"][1]["index"] = 0
                denied("marble_geometry_plan", plan(shifted_index), "marble_geometry_invalid_proof")
                outside = parent / "outside-owned.json"
                outside.write_bytes(first_bytes)
                denied("world_blob_put", {"sha256": first, "mime": "application/json", "localPath": str(outside)}, "blob_outside_private_root")
                first_path.write_bytes(bytes([first_bytes[0] ^ 1]) + first_bytes[1:])
                denied("marble_geometry_plan", plan(geometry), "marble_geometry_invalid_proof")
                first_path.write_bytes(first_bytes)
                first_path.unlink(); first_path.symlink_to(outside)
                denied("marble_geometry_plan", plan(geometry), "marble_geometry_invalid_proof")
                first_path.unlink(); first_path.write_bytes(first_bytes)

                probes = page["probes"] + next_page["probes"]

                def row(index, ground=0, occupancy=True):
                    return {"key": probes[index]["key"], "position": probes[index]["position"],
                            "groundHeight": ground, "canOccupy": occupancy}

                def resolve(rows, *, reverse_chunks=False, wrong_hash=False):
                    chunks = [put({"offset": i, "measurements": [value]})[0] for i, value in enumerate(rows)]
                    return {"geometry": geometry, "planHash": "0" * 64 if wrong_hash else page["planHash"],
                            "measurementCount": len(rows), "measurementChunks": list(reversed(chunks)) if reverse_chunks else chunks}

                resolved = ok("marble_geometry_resolve", resolve([row(0)]))
                assert resolved["selectedProbeKey"] == "triangle:0" and resolved["planHash"] == page["planHash"]
                assert resolved["spawn"]["position"] == {"x": 0, "y": 0, "z": 0}
                assert resolved["camera"]["transform"]["position"]["y"] == 1.5
                denied("marble_geometry_resolve", resolve([row(1)]), "marble_geometry_incomplete_proof")
                denied("marble_geometry_resolve", resolve([row(0, occupancy=False)]), "marble_geometry_incomplete_proof")
                assert ok("marble_geometry_resolve", resolve([row(0, occupancy=False), row(1)]))["selectedProbeKey"] == "triangle:1"
                denied("marble_geometry_resolve", resolve([row(0), row(1)], reverse_chunks=True), "marble_geometry_invalid_proof")
                denied("marble_geometry_resolve", resolve([row(0)], wrong_hash=True), "marble_geometry_plan_mismatch")
                changed = row(0); changed["position"] = [0.001, 0, 0]
                denied("marble_geometry_resolve", resolve([changed]), "marble_geometry_invalid_proof")
                assert ok("marble_geometry_resolve", resolve([row(0, ground=.049)]))["selectedProbeKey"] == "triangle:0"
                denied("marble_geometry_resolve", resolve([row(0, ground=.05), row(1, occupancy=False)]), "marble_geometry_no_spawn")
                denied("marble_geometry_resolve", resolve([row(0, ground=.051), row(1, occupancy=False)]), "marble_geometry_no_spawn")
                database = next(root.glob("*.sqlite*"))
                with sqlite3.connect(database) as db:
                    assert db.execute("SELECT count(*) FROM world_records").fetchone()[0] == 0
                    count = db.execute("SELECT count(*) FROM world_blobs").fetchone()[0]
                    assert count >= 2
                print(f"PASS real HTTP/SQLite/SHA geometry paging, missing/corrupt/outside proofs, exact samples/positions, strict threshold; {count} actual blob records; no world registration/Unity visual claim", flush=True)
            finally:
                os.killpg(daemon.pid, signal.SIGTERM)
                try: daemon.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(daemon.pid, signal.SIGKILL); daemon.wait(timeout=5)
                for target in (lambda: os.kill(daemon.pid, 0), lambda: os.killpg(daemon.pid, 0)):
                    try: target(); raise AssertionError("owned private process survived")
                    except ProcessLookupError: pass
                print(f"REAPED private daemon PID/PGID={daemon.pid} exit={daemon.returncode}", flush=True)
    assert not parent.exists()
    print("PASS exact private root removed", flush=True)


if __name__ == "__main__":
    main()
