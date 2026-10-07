#!/usr/bin/env python3
"""Silent public-source playback against a fresh, isolated production taskd."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import threading
import time
import urllib.request
import urllib.parse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", default="tmp/unity-player-release-v193.app")
    parser.add_argument("--url", default="https://www.youtube.com/watch?v=0w-nL_Qr_Do")
    parser.add_argument("--daemon", default="target/debug/gmgn-taskd")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--first-frame-timeout", default="120")
    args = parser.parse_args()
    root = pathlib.Path.cwd()
    helpers = (root / args.bundle / "Contents/Resources/Helpers").resolve()
    manifest = json.loads((root / "tools/helpers/screen-link-helpers.lock.json").read_text())
    hashes = {item["name"]: item["sha256"] for item in manifest["helpers"]}
    for name in ("yt-dlp", "deno"):
        assert hashlib.sha256((helpers / name).read_bytes()).hexdigest() == hashes[name], "Pinned helper mismatch"
    with tempfile.TemporaryDirectory(prefix="gmgn-public-media-") as temporary:
        private = pathlib.Path(temporary).resolve()
        endpoint = private / "taskd.endpoint.json"
        daemon_binary = (root / args.daemon).resolve()
        print("DAEMON verified_binary_sha256=" + hashlib.sha256(daemon_binary.read_bytes()).hexdigest(), flush=True)
        diagnostic_log = private / "daemon-diagnostics.log"
        log_output = diagnostic_log.open("wb")
        daemon_environment = dict(os.environ)
        if args.debug:
            daemon_environment["GMGN_MEDIA_RANGE_TRACE"] = "1"
        daemon = subprocess.Popen([str(daemon_binary), "--root", str(private),
                                   "--endpoint-file", str(endpoint), "--concurrency", "2",
                                   "--media-helper", str(helpers / "yt-dlp"), "--media-helper-sha256", hashes["yt-dlp"],
                                   "--media-deno", str(helpers / "deno"), "--media-deno-sha256", hashes["deno"]],
                                  stdout=subprocess.DEVNULL, stderr=log_output, env=daemon_environment)
        monitor_stop = threading.Event()
        states = set()
        try:
            deadline = time.monotonic() + 20
            while not endpoint.exists() and time.monotonic() < deadline and daemon.poll() is None:
                time.sleep(.1)
            assert endpoint.exists(), "Isolated daemon did not publish endpoint"
            descriptor = json.loads(endpoint.read_text())
            assert descriptor["version"] == 2 and descriptor["address"].startswith("127.0.0.1:"), "Wrong isolated HTTP endpoint"
            page = args.url
            parsed = urllib.parse.urlsplit(page)
            if parsed.hostname in ("youtube.com", "www.youtube.com", "m.youtube.com"):
                video_id = urllib.parse.parse_qs(parsed.query).get("v", [None])[0]
                if video_id:
                    page = "https://www.youtube.com/watch?v=" + video_id
            elif parsed.hostname == "youtu.be":
                page = "https://www.youtube.com/watch?v=" + parsed.path.lstrip("/")
            key = hashlib.sha256(("public-video-v1|" + page + "|2160|avc1|mp4a").encode()).hexdigest()
            def rpc(method, params):
                request = urllib.request.Request("http://" + descriptor["address"] + "/rpc",
                    data=json.dumps(dict(id="public-probe-monitor", method=method, params=params)).encode(),
                    headers={"Content-Type": "application/json", "Authorization": "Bearer " + descriptor["token"]})
                with urllib.request.urlopen(request, timeout=10) as response:
                    return json.load(response).get("result", {})
            def monitor():
                raw_checked = False
                seen_errors = set()
                began = time.monotonic()
                while not monitor_stop.wait(.2):
                    try:
                        status = rpc("media_status", dict(cacheKey=key))
                        state = status.get("state")
                        if state:
                            if state not in states:
                                print(f"PUBLIC_STATE state={state} elapsed={time.monotonic()-began:.2f}", flush=True)
                            states.add(state)
                        error = status.get("error")
                        code = error.get("code") if isinstance(error, dict) else error
                        if code and isinstance(code, str) and code.replace("_", "").isalnum() and code not in seen_errors:
                            seen_errors.add(code)
                            print(f"PUBLIC_ERROR code={code}", flush=True)
                        if args.debug and state == "downloading" and not raw_checked and \
                           status.get("streamingDescriptor", {}).get("video", {}).get("url", "").startswith("/media/"):
                            raw_checked = True
                            total = None
                            for kind, start, length in [("video", 0, 2), ("video", 0, 1048576),
                                                        ("video", -1, 1048576), ("audio", 0, 2)]:
                                if start == -1:
                                    if total is None:
                                        continue
                                    start = max(0, total - length)
                                requested = f"bytes={start}-{start + length - 1}"
                                request = urllib.request.Request("http://" + descriptor["address"] + f"/media/{key}/{kind}",
                                    headers={"Range": requested, "Authorization": "Bearer " + descriptor["token"]})
                                began = time.monotonic()
                                try:
                                    with urllib.request.urlopen(request, timeout=15) as response:
                                        content_range = response.headers.get("Content-Range", "")
                                        payload = response.read(1048577)
                                        matched = re.fullmatch(r"bytes \d+-\d+/(\d+)", content_range)
                                        if matched and kind == "video":
                                            total = int(matched[1])
                                        print(f"RAW_RANGE kind={kind} range={requested} status={response.status} contentRange={content_range} bytes={len(payload)} seconds={time.monotonic()-began:.2f}", flush=True)
                                except urllib.error.HTTPError as error:
                                    payload = json.loads(error.read(4096))
                                    code = payload.get("error", {}).get("code", "unknown")
                                    if not isinstance(code, str) or not code.replace("_", "").isalnum():
                                        code = "unknown"
                                    print(f"RAW_RANGE kind={kind} range={requested} status={error.code} code={code}", flush=True)
                                except Exception:
                                    print(f"RAW_RANGE kind={kind} range={requested} failed=true", flush=True)
                    except Exception:
                        pass
            thread = threading.Thread(target=monitor, daemon=True)
            thread.start()
            environment = dict(os.environ, GMGN_MEDIA_CACHE_ENDPOINT=str(endpoint), GMGN_NATIVE_LINK_SILENT="1",
                               GMGN_CACHE_FIRST_FRAME_TIMEOUT=args.first_frame_timeout)
            if args.debug:
                environment["GMGN_SCREEN_LINK_DEBUG"] = "1"
            result = subprocess.run(["swift", "tools/probe-native-link-playback.swift", args.url, "20"],
                                    env=environment, capture_output=True, text=True, timeout=180)
            # Only emit the probe's sanitized counters, never source signatures or helper logs.
            for line in result.stdout.splitlines():
                if line.startswith("CACHE_PROBE ") or line.startswith("CACHE_FIRST_FRAME "):
                    print(line, flush=True)
            if result.returncode != 0:
                for line in result.stderr.splitlines():
                    if re.match(r"^.*\.swift:\d+:\d+: error:", line):
                        print("PUBLIC_COMPILE " + line, flush=True)
            if args.debug:
                for line in result.stderr.splitlines():
                    if line.startswith("RESLOAD ") or "[ScreenLinkPreparation] phase=" in line:
                        print(line, flush=True)
                for line in diagnostic_log.read_text(errors="replace").splitlines():
                    if line.startswith("MEDIA_PLAYBACK_RANGE "):
                        print(line, flush=True)
            monitor_stop.set()
            thread.join(timeout=12)
            terminal = rpc("media_status", dict(cacheKey=key))
            final = terminal.get("state")
            print("PUBLIC_CACHE states=" + ",".join(sorted(states)) + " final=" + str(final), flush=True)
            if terminal.get("error"):
                error = terminal["error"]
                code = error.get("code", "unknown") if isinstance(error, dict) else error
                if isinstance(code, str) and code.replace("_", "").isalnum():
                    print("PUBLIC_CACHE failure_code=" + code, flush=True)
            assert result.returncode == 0, "Public native playback failed; raw helper diagnostics withheld"
            assert "silent=true" in result.stdout, "Public probe did not verify player silence"
            assert "isManifest=true" in result.stdout, "Public probe did not use the streaming manifest"
            first_frame = next((line for line in result.stdout.splitlines() if line.startswith("CACHE_FIRST_FRAME ")), "")
            assert "cacheState=downloading" in first_frame, "First frame did not precede full cache completion"
            assert "downloading" in states, "Public source was not observed downloading"
            assert final in ("ready", "cancelled"), "Playback owner left unfinished cache work"
            print("PASS fresh public source -> production Rust HTTP -> silent native frames/GPU with audio track before ready; stopped cache=" + str(final), flush=True)
        finally:
            monitor_stop.set()
            if daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait()
            log_output.close()


if __name__ == "__main__":
    main()
