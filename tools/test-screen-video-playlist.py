#!/usr/bin/env python3
"""Isolated, strictly muted production AVPlayer end -> durable queue advance contract.

Uses a bounded authenticated RPC fixture; Rust playlist extraction/CAS/prefetch
are covered independently. No installed app, formal DB or system audio access.
Compile is the existing probe's single-job swiftc, never SwiftPM.
"""
import http.server
import argparse
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import time
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", action="store_true", help="Exercise the real separate-track composition EOF path")
    parser.add_argument("--hls", action="store_true", help="Exercise finite VOD HLS natural EOF")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="gmgn-screen-playlist-") as temporary:
        private = pathlib.Path(temporary)
        video = private / "short.mp4"
        subprocess.run(["/opt/homebrew/bin/ffmpeg", "-hide_banner", "-loglevel", "error",
                        "-threads", "1", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2.2",
                        "-c:v", "libx264", "-threads:v", "1", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-movflags", "+faststart", str(video)], check=True)
        token = str(uuid.uuid4())
        ids = ["aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc", "ddddddddddd"]
        live_resources = {}
        manifests = {}
        if options.hls:
            manifest_file = private / "vod.m3u8"
            subprocess.run(["/opt/homebrew/bin/ffmpeg", "-hide_banner", "-loglevel", "error", "-threads", "1",
                            "-i", str(video), "-c", "copy", "-hls_time", "1", "-hls_playlist_type", "vod",
                            str(manifest_file)], check=True)
            for video_id in ids:
                capability, resource = str(uuid.uuid4()), str(uuid.uuid4())
                path = f"/media-live/{capability}/{resource}"
                rows = []
                for line in manifest_file.read_text().splitlines():
                    if line and not line.startswith("#"):
                        segment = f"/media-live/{capability}/{uuid.uuid4()}"
                        live_resources[segment] = ((private / line).read_bytes(), "video/mp2t")
                        line = segment
                    rows.append(line)
                live_resources[path] = (("\n".join(rows) + "\n").encode(), "application/vnd.apple.mpegurl")
                manifests[video_id] = path
        pages = ["https://www.youtube.com/watch?v=" + video_id for video_id in ids]
        calls, queues = [], {}
        lock = threading.Lock()

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def do_POST(self):
                assert self.path == "/rpc"
                assert self.headers.get("Authorization") == "Bearer " + token
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                method, params = body["method"], body["params"]
                failure = None
                with lock:
                    calls.append((method, params, time.monotonic()))
                if method == "media_playlist_import":
                    late = "PLlate" in params["pageURL"]
                    if late:
                        time.sleep(.8)
                    result = dict(playlistID=params["playlistID"], revision=1, currentIndex=1,
                                  items=[dict(pageURL=page) for page in pages], truncated=False, itemLimit=200,
                                  _failAdvance="PLadvanceFail" in params["pageURL"])
                    queues[params["playlistID"]] = result
                elif method == "media_playlist_advance":
                    # Force cancelled old downloading poll to run while advance is in flight.
                    time.sleep(.6)
                    result = dict(queues[params["playlistID"]])
                    assert params["baseRevision"] == result["revision"]
                    if result["_failAdvance"]:
                        failure = dict(code="media_playlist_fixture_failure")
                    else:
                        result.update(revision=result["revision"] + 1, currentIndex=result["currentIndex"] + 1)
                        queues[params["playlistID"]] = result
                elif method == "media_playlist_release":
                    queues.pop(params["playlistID"], None)
                    result = dict(released=True)
                elif method in ("media_prepare", "media_status"):
                    video_id = params["pageURL"].split("v=")[1] if method == "media_prepare" else params["cacheKey"]
                    result = dict(cacheKey=video_id, state="downloading", streamingDescriptor=dict(
                        pageURL=pages[ids.index(video_id)], site="youtube", title="short silent fixture",
                        durationSeconds=2.2, isLive=False, audio=None, video=dict(
                            url="/media/" + video_id + "/video", formatID="fixture", container="mp4",
                            videoCodec="avc1", audioCodec="mp4a", width=320, height=180,
                            isManifest=False, hasVideo=True, hasAudio=True, headers={})))
                    if options.split:
                        result["streamingDescriptor"]["audio"] = dict(
                            result["streamingDescriptor"]["video"],
                            url="/media/" + video_id + "/audio", hasVideo=False)
                    if options.hls:
                        result["streamingDescriptor"]["video"].update(
                            url=manifests[video_id], isManifest=True, container="m3u8")
                elif method in ("media_release", "media_cancel"):
                    result = dict(released=True)
                else:
                    raise AssertionError(method)
                payload = json.dumps(dict(id=body["id"], error=failure) if failure else dict(id=body["id"], result=result)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):
                if self.path in live_resources:
                    data, content_type = live_resources[self.path]
                    self.send_response(200)
                    self.send_header("Content-Type", content_type)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                assert self.headers.get("Authorization") == "Bearer " + token
                assert self.path.startswith("/media/")
                size = video.stat().st_size
                start, end = 0, size - 1
                requested = self.headers.get("Range")
                if requested:
                    start_string, end_string = requested.removeprefix("bytes=").split("-")
                    start = int(start_string)
                    if end_string:
                        end = min(int(end_string), end)
                self.send_response(206 if requested else 200)
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(end - start + 1))
                if requested:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                self.end_headers()
                try:
                    with video.open("rb") as source:
                        source.seek(start)
                        self.wfile.write(source.read(end - start + 1))
                except (BrokenPipeError, ConnectionResetError):
                    pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        endpoint = private / "taskd.endpoint.json"
        endpoint.write_text(json.dumps(dict(version=2, address=f"127.0.0.1:{server.server_port}", token=token)))
        environment = dict(os.environ, GMGN_NATIVE_LINK_SILENT="1", GMGN_CACHE_PLAYLIST_FIXTURE="1",
                           GMGN_MEDIA_CACHE_ENDPOINT=str(endpoint),GMGN_PLAYLIST_FIXTURE_FILE=str(video))
        try:
            result = subprocess.run(["swift", "tools/probe-native-link-playback.swift",
                                     "https://youtube.com/watch?v=bbbbbbbbbbb&list=PLfixture&index=2"],
                                    env=environment, timeout=180)
            assert result.returncode == 0, "Native playlist probe failed"
            advances = [call for call in calls if call[0] == "media_playlist_advance"]
            prepares = [call for call in calls if call[0] == "media_prepare"]
            imports = [call for call in calls if call[0] == "media_playlist_import"]
            releases = [call for call in calls if call[0] == "media_playlist_release"]
            normal_id=imports[0][1]["playlistID"]
            normal_advances=[call for call in advances if call[1]["playlistID"] == normal_id]
            assert len(normal_advances) == 1 and len(advances) == 2, "Only normal end and injected advance failure attempted"
            assert [call[1]["pageURL"] for call in prepares] == pages[1:3] + [pages[1]], "Only requested current and next played"
            assert advances[0][2] - prepares[0][2] >= 2, "Ready/download completion must not advance the queue"
            assert len(imports) == 3 and len(releases) >= 3 and not queues, "Late import and failures must release ownership"
            print("PLAYLIST_RPC current_and_next_only=true cache_always_downloading=true actual_end_advance=true stop_no_advance=true late_import_released=true PASS")
        finally:
            server.shutdown()


if __name__ == "__main__":
    main()
