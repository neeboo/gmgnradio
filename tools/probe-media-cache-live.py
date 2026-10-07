#!/usr/bin/env python3
"""Isolated taskd full cache -> production Swift playback; no signed URL output."""
import argparse
import http.client
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--helpers", type=Path, required=True)
    parser.add_argument("--video-id", required=True)
    args = parser.parse_args()
    base = Path(__file__).resolve().parent.parent
    page = "https://www.youtube.com/watch?v=" + args.video_id
    with tempfile.TemporaryDirectory(prefix="gmgn-live-cache-") as temporary:
        root = Path(temporary).resolve()
        endpoint = root / "taskd.endpoint.json"
        command = [str(base / "target/debug/gmgn-taskd"), "--root", str(root),
                   "--endpoint-file", str(endpoint), "--concurrency", "2"]
        for name, flag in [("yt-dlp", "media-helper"), ("deno", "media-deno")]:
            command += ["--" + flag, str(args.helpers.resolve() / name),
                        "--" + flag + "-sha256",
                        (args.helpers / (name + ".sha256")).read_text().split()[0]]
        daemon = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(200):
                if endpoint.exists():
                    break
                if daemon.poll() is not None:
                    raise RuntimeError("isolated daemon startup failed")
                time.sleep(.05)
            descriptor = json.loads(endpoint.read_text())
            host, port = descriptor["address"].rsplit(":", 1)

            def rpc(method, params):
                connection = http.client.HTTPConnection(host, int(port), timeout=15)
                connection.request("POST", "/rpc", json.dumps(dict(id="probe", method=method, params=params)),
                                   {"Authorization": "Bearer " + descriptor["token"], "Content-Type": "application/json"})
                value = json.loads(connection.getresponse().read())
                connection.close()
                if "error" in value:
                    raise RuntimeError("isolated RPC failed")
                return value["result"]

            started = time.monotonic()
            value = rpc("media_prepare", dict(pageURL=page, maxHeight=2160, consumerID="isolated-live-probe", pin=True))
            key, previous = value["cacheKey"], None
            while time.monotonic() - started < 620:
                value = rpc("media_status", dict(cacheKey=key))
                if value["state"] != previous:
                    print(json.dumps(dict(state=value["state"], elapsed_seconds=round(time.monotonic() - started))), flush=True)
                    previous = value["state"]
                if value["state"] in ["ready", "failed", "cancelled", "interrupted"]:
                    break
                time.sleep(1)
            if value["state"] != "ready":
                print(json.dumps(dict(full_cache="failed", state=value["state"], error=value.get("errorCode", value.get("error")))), flush=True)
                return 1
            media = value["descriptor"]
            print(json.dumps(dict(full_cache="ready", video_bytes=media["video"].get("bytes"),
                                  audio_bytes=media["audio"].get("bytes"), video_height=media["video"].get("height"))), flush=True)
            result = subprocess.run(["swift", "tools/probe-native-link-playback.swift", page, "30"], cwd=base,
                                    env=dict(os.environ, GMGN_MEDIA_CACHE_ENDPOINT=str(endpoint)), timeout=120,
                                    capture_output=True, text=True)
            print(result.stdout, flush=True)
            print(json.dumps(dict(swift_probe_exit=result.returncode, stderr_bytes=len(result.stderr))), flush=True)
            return result.returncode
        finally:
            daemon.terminate()
            try:
                _, errors = daemon.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                daemon.kill()
                _, errors = daemon.communicate()
            for line in errors.splitlines():
                if line.startswith("media download connect ") or line.startswith("media download source refresh "):
                    print(line, flush=True)
            print(json.dumps(dict(resolve_generations=1 + errors.count("media download source refresh after exhausted TLS EOF:"))), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
